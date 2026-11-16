local addon = WMacroCompiler

--[[-----------------------------------------------------------------------------
Theme: the steampunk art kit (Media/*.tga, laid out by Media/ThemeData.lua,
which tools/build_theme.py generates from the source sheets).

Everything here is plain 3.3.5a texture work -- SetTexture + SetTexCoord on
our own frames -- so the look does not depend on any other addon. Two kinds
of art:

  * Pieces: widget parts (buttons, fields, tabs, panels, scrollbar...). A
    piece may carry slice margins; a Slice draws it as 1, 3 (horizontal or
    vertical) or 9 textures so it stretches to any size without distorting
    its caps and corners. Margins and sizes are UI units (one texel each).
  * Frames: the pipe frame of a fixed-size window, composed offline into
    tiles placed at fixed offsets from the window's top-left corner, plus
    the close-button opening and the title plaque's face.
-------------------------------------------------------------------------------]]
local Theme = {}
addon.Theme = Theme

local data = addon.ThemeData
local PATH = data.path

Theme.colors = {
    gold = { 1, 0.82, 0 },
    title = { 1, 0.86, 0.45 },
    -- A window's title on its plaque: the plaque rim's lit brass, to match
    -- the window's.
    windowTitle = { 0.93, 0.75, 0.35 },
    label = { 1, 0.82, 0 },
    tabText = { 0.17, 0.10, 0.03 },
    text = { 1, 1, 1 },
    dim = { 0.5, 0.5, 0.5 },
    caption = { 0.6, 0.8, 1 },
    -- The list icons' drawn rim: the icon slot's outer dark band and its lit
    -- brass band, sampled from the "icon-slot" piece.
    rimDark = { 0.22, 0.11, 0.01 },
    rimBrass = { 0.55, 0.38, 0.12 },
}

-- The size of one screen pixel in `frame`'s units, or nil when it can't be
-- known (no scale yet, no resolution). Depends on the UI scale and the
-- resolution, so it is read when needed, never cached.
function Theme.PixelSize(frame)
    local scale = frame and frame.GetEffectiveScale and frame:GetEffectiveScale()
    local _, height = Theme.ScreenPixels()
    if not scale or scale <= 0 or not height then
        return nil
    end
    return 768 / height / scale
end

local function parseResolution(resolution)
    local width, height = (type(resolution) == "string" and resolution or ""):match("^(%d+)x(%d+)")
    width, height = tonumber(width), tonumber(height)
    if width and width >= 1 and height and height >= 1 then
        return width, height
    end
end

-- The screen (or the game window, when windowed) in pixels: width, height;
-- nil when unknown. 3.3.5a has no gxWindowedResolution (later clients
-- do): gxResolution is the window's size there too. Last resort: the
-- resolution list's current entry.
function Theme.ScreenPixels()
    local width, height
    if GetCVar then
        if GetCVar("gxWindow") == "1" then
            width, height = parseResolution(GetCVar("gxWindowedResolution"))
        end
        if not width then
            width, height = parseResolution(GetCVar("gxResolution"))
        end
    end
    if not width and GetCurrentResolution and GetScreenResolutions then
        local index = GetCurrentResolution()
        width, height = parseResolution(index and index > 0 and (select(index, GetScreenResolutions())))
    end
    return width, height
end

--[[ Window scale ]]

-- The addon's windows (main, text, guide) and their popups share a scale
-- of their own, apart from the UI scale. The art is composed at one texel
-- per unit: drawn at a whole number of screen pixels per unit it is exact
-- (crisp), stretched in between it blurs. So the windows are drawn at the
-- largest whole number of pixels per unit at which the main window's art
-- (its column and plaque included) fits WINDOW_FIT of the screen -- 1 on
-- 1080p and 1440p, 2 on 4K -- or below 1 where even 1:1 does not fit.
-- The size setting (/qmc size, settings.windowSize) scales that by
-- WINDOW_SIZES, never past the fit. Unknown resolution: scale 1.
Theme.WINDOW_SIZES = { smaller = 0.8, normal = 1, larger = 1.25 }
Theme.WINDOW_FIT = 0.92

-- Screen pixels per unit for the windows at `size`, or nil.
function Theme.WindowPixels(size)
    local width, height = Theme.ScreenPixels()
    if not height then
        return nil
    end
    local frameData = data.frames.main
    local fit = Theme.WINDOW_FIT * math.min(width / frameData.reach,
        height / (frameData.height + Theme.ArtAbove("main")))
    local pixels = fit >= 1 and math.floor(fit) or fit
    return math.min(pixels * (Theme.WINDOW_SIZES[size] or 1), fit)
end

-- The SetScale value that draws a window (a child of UIParent) at `size`.
function Theme.WindowScale(size)
    local pixels = Theme.WindowPixels(size)
    local _, height = Theme.ScreenPixels()
    local ui = UIParent and UIParent.GetEffectiveScale and UIParent:GetEffectiveScale()
    if not pixels or not ui or ui <= 0 then
        return 1
    end
    return pixels / (height / 768 * ui)
end

-- The scale for the size the player chose.
function Theme.AddonScale()
    local settings = addon.db and addon.db.settings
    return Theme.WindowScale(settings and settings.windowSize)
end

-- Sets a popup (a child of UIParent) to the windows' scale.
function Theme.ScalePopup(frame)
    if frame and frame.SetScale then
        frame:SetScale(Theme.AddonScale())
    end
end

-- UIParent's width in `frame`'s units (a frame at another scale).
function Theme.RoomFor(frame)
    local width = UIParent:GetWidth() or 0
    local ui = UIParent.GetEffectiveScale and UIParent:GetEffectiveScale()
    local own = frame and frame.GetEffectiveScale and frame:GetEffectiveScale()
    if ui and own and own > 0 then
        return width * ui / own
    end
    return width
end

-- `value` (frame units) on the nearest whole screen pixel.
function Theme.SnapToPixel(frame, value)
    local pixel = Theme.PixelSize(frame)
    if not pixel then
        return value
    end
    return math.floor(value / pixel + 0.5) * pixel
end

-- The text boxes' font (the editors, the fields, the guide's examples),
-- at a size of its own. They used to be drawn in ChatFontNormal, which
-- takes the chat window's font size (the chat menu's, or ElvUI's), so they
-- came out big on one character and small on another. The face is
-- Quintessence Adventor Medium (Media/Fonts), an Avant Garde Medium; it
-- has Latin letters only, so the other clients keep the chat font's face
-- (read on each call: ElvUI sets it after login).
Theme.TEXT_FONT_SIZE = 12
Theme.TEXT_FONT_FILE = "Fonts\\QuintessenceAdventor.ttf" -- under Media
local LATIN_LOCALES = { enUS = true, enGB = true, deDE = true, frFR = true, esES = true, esMX = true }

function Theme.TextFont()
    if not (CreateFont and ChatFontNormal and ChatFontNormal.GetFont) then
        return ChatFontNormal
    end
    local font = Theme.textFont
    if not font then
        font = CreateFont("QuintessenceTextFont")
        Theme.textFont = font
    end
    local data = addon.ThemeData
    if data and LATIN_LOCALES[GetLocale and GetLocale() or "enUS"] then
        font:SetFont(data.path .. Theme.TEXT_FONT_FILE, Theme.TEXT_FONT_SIZE, "")
    else
        local file = ChatFontNormal:GetFont()
        font:SetFont(file, Theme.TEXT_FONT_SIZE, "")
    end
    font:SetShadowOffset(1, -1)
    font:SetShadowColor(0, 0, 0, 1)
    return font
end

-- Title font: Morpheus ships with the 3.3.5a client.
Theme.TITLE_FONT = "Fonts\\MORPHEUS.TTF"
Theme.TITLE_FONT_SIZE = 18
Theme.TITLE_FONT_SIZES = { main = 25, bank = 22, guide = 15 }
Theme.TITLE_PAD = 8   -- units kept clear at each end of the plaque's face
Theme.TITLE_SHRINK = 3   -- points a title may lose before it is cut short
-- Units each window's title sits above its plaque face's middle. One value
-- for all used to be shared: raised for the main window (its title looked
-- too low), it left the export / import window's too high, so each frame
-- has its own. (That window now has the popup look, POPUP_FRAMES: its
-- title is on its tab.)
Theme.TITLE_LIFT = { main = 2, bank = 1, guide = 2 }
-- The title's colour where it is not Theme.colors.windowTitle (light on a dark
-- face): on Quintessence Macros' brass plate, dark like the guide's, with no
-- shadow.
Theme.TITLE_DARK = { bank = true }

-- Shows the first of texts that fits width on fontString; if none does, the
-- last one cut short (whole UTF-8 characters) with "...". Without a way to
-- measure, shows the first.
function Theme.FitText(fontString, width, texts)
    local measure = fontString.GetStringWidth
    local function fits(text)
        fontString:SetText(text)
        return not measure or (measure(fontString) or 0) <= width
    end
    for _, text in ipairs(texts) do
        if fits(text) then
            return text
        end
    end
    local last = texts[#texts] or ""
    local chars = {}
    for char in last:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        chars[#chars + 1] = char
    end
    for n = #chars - 1, 0, -1 do
        local text = table.concat(chars, "", 1, n):gsub("%s+$", "") .. "..."
        if fits(text) or n == 0 then
            return text
        end
    end
    fontString:SetText(last)
    return last
end

function Theme.Piece(name)
    local piece = data.pieces[name]
    if not piece then
        error("WMC theme: unknown piece " .. tostring(name), 2)
    end
    return piece
end

function Theme.PieceSize(name)
    local piece = Theme.Piece(name)
    return piece[6], piece[7]
end

-- Puts a whole piece on a texture.
function Theme.SetPiece(texture, name)
    local piece = Theme.Piece(name)
    texture:SetTexture(PATH .. piece[1])
    texture:SetTexCoord(piece[2], piece[3], piece[4], piece[5])
end

-- Sets one of a Button's state textures to a whole piece. `kind` is
-- "Normal", "Pushed", "Disabled" or "Highlight" (drawn with BLEND, so the
-- hover art replaces the normal art instead of brightening it).
function Theme.SetButtonPiece(button, kind, name)
    local piece = Theme.Piece(name)
    local path = PATH .. piece[1]
    local texture
    if kind == "Highlight" then
        button:SetHighlightTexture(path, "BLEND")
        texture = button:GetHighlightTexture()
    else
        button["Set" .. kind .. "Texture"](button, path)
        texture = button["Get" .. kind .. "Texture"](button)
    end
    if texture and texture.SetTexCoord then
        texture:SetTexCoord(piece[2], piece[3], piece[4], piece[5])
        texture:ClearAllPoints()
        texture:SetAllPoints(button)
    end
    return texture
end

-- A button's hover art is drawn over its pressed art: it hides while the
-- button is held, or "pressed" only shows once the cursor leaves (the close
-- buttons; the icon buttons, whose hover is opaque; the rail's, whose
-- additive glow undid the pressed darkening). The
-- hover's own alpha comes back on release.
local function HoverOff_OnMouseDown(button)
    local hover = button:GetHighlightTexture()
    if hover then
        local alpha = hover:GetAlpha()
        if alpha > 0 then
            button.wmcHoverAlpha = alpha
        end
        hover:SetAlpha(0)
    end
end

local function HoverOff_OnMouseUp(button)
    local hover = button:GetHighlightTexture()
    if hover then
        hover:SetAlpha(button.wmcHoverAlpha or 1)
    end
end

function Theme.HideHoverWhileHeld(button)
    button:SetScript("OnMouseDown", HoverOff_OnMouseDown)
    button:SetScript("OnMouseUp", HoverOff_OnMouseUp)
end

-- A square button drawn by a piece and its "-hover" / "-pressed" pieces
-- (the flyout's padlock). button:SetIcon(name) swaps all three.
function Theme.CreateIconButton(parent)
    local button = CreateFrame("Button", nil, parent)
    Theme.HideHoverWhileHeld(button)
    function button:SetIcon(name)
        if name == self.icon then
            return
        end
        self.icon = name
        local width, height = Theme.PieceSize(name)
        self:SetWidth(width)
        self:SetHeight(height)
        Theme.SetButtonPiece(self, "Normal", name)
        Theme.SetButtonPiece(self, "Highlight", name .. "-hover")
        Theme.SetButtonPiece(self, "Pushed", name .. "-pressed")
    end
    return button
end

-- A rail button's art from one piece (the Compiler's rail, the bank
-- editor's icons): the piece; hovered, itself added over at half strength;
-- pressed, darker; disabled, grey. Pair with Theme.HideHoverWhileHeld.
local RAIL_GREY = 0.55
function Theme.SetRailPiece(button, piece)
    Theme.SetButtonPiece(button, "Normal", piece)
    local glow = Theme.SetButtonPiece(button, "Highlight", piece)
    if glow and glow.SetBlendMode then
        glow:SetBlendMode("ADD")
        glow:SetAlpha(0.5)
    end
    button.wmcHoverAlpha = 0.5
    local pushed = Theme.SetButtonPiece(button, "Pushed", piece)
    if pushed and pushed.SetVertexColor then
        pushed:SetVertexColor(0.75, 0.75, 0.75)
    end
    local disabled = Theme.SetButtonPiece(button, "Disabled", piece)
    if disabled then
        if disabled.SetDesaturated then
            disabled:SetDesaturated(true)
        end
        if disabled.SetVertexColor then
            disabled:SetVertexColor(RAIL_GREY, RAIL_GREY, RAIL_GREY)
        end
    end
end

--[[ Slices ]]
local Slice = {}
Slice.__index = Slice

-- A Slice draws a piece over `frame` (optionally outset by
-- left/right/top/bottom units). Changing the piece keeps the geometry.
function Theme.CreateSlice(frame, layer, subLevel)
    local slice = setmetatable({ frame = frame, layer = layer or "BACKGROUND", subLevel = subLevel or 0,
        textures = {}, outset = { 0, 0, 0, 0 }, shown = true, scale = 1, hollow = false }, Slice)
    return slice
end

function Slice:Texture(index)
    local texture = self.textures[index]
    if not texture then
        texture = self.frame:CreateTexture(nil, self.layer)
        if texture.SetDrawLayer and self.subLevel ~= 0 then
            texture:SetDrawLayer(self.layer, self.subLevel)
        end
        self.textures[index] = texture
    end
    return texture
end

-- Draws the caps and corners `scale` times their texel size (the middle
-- still stretches), so a piece can frame something smaller than its art.
function Slice:SetScale(scale)
    self.scale = scale or 1
    if self.piece then
        self:Layout()
    end
end

-- A hollow 9-slice leaves out its middle cell: only the border is drawn.
function Slice:SetHollow(hollow)
    self.hollow = hollow and true or false
    if self.piece then
        self:Layout()
    end
end

function Slice:SetOutset(left, right, top, bottom)
    self.outset = { left or 0, right or 0, top or 0, bottom or 0 }
    if self.piece then
        self:Layout()
    end
end

-- Texture coordinate `fraction` of the way across [a, b].
local function lerp(a, b, fraction)
    return a + (b - a) * fraction
end

function Slice:Layout()
    local piece = self.piece
    local file, l, r, t, b, w, h, sl, sr, st, sb = unpack(piece)
    local frame = self.frame
    local ol, orr, ot, ob = unpack(self.outset)
    local path = PATH .. file
    -- Column and row boundaries in texture space, and the cap sizes in units.
    local us = { l, lerp(l, r, sl / w), lerp(l, r, 1 - sr / w), r }
    local vs = { t, lerp(t, b, st / h), lerp(t, b, 1 - sb / h), b }
    local scale = self.scale
    sl, sr, st, sb = sl * scale, sr * scale, st * scale, sb * scale
    local columns = (sl > 0 or sr > 0) and 3 or 1
    local rows = (st > 0 or sb > 0) and 3 or 1
    if columns == 1 then
        us = { l, l, r, r }
    end
    if rows == 1 then
        vs = { t, t, b, b }
    end
    -- Cell edges relative to the frame: { anchor, offset } per edge. WoW y
    -- grows upward, so "down from the top" is a negative offset.
    local columnEdges = {
        { { "LEFT", -ol }, { "LEFT", sl - ol } },
        { { "LEFT", columns == 3 and (sl - ol) or -ol }, { "RIGHT", columns == 3 and (orr - sr) or orr } },
        { { "RIGHT", orr - sr }, { "RIGHT", orr } },
    }
    local rowEdges = {
        { { "TOP", ot }, { "TOP", ot - st } },
        { { "TOP", rows == 3 and (ot - st) or ot }, { "BOTTOM", rows == 3 and (sb - ob) or -ob } },
        { { "BOTTOM", sb - ob }, { "BOTTOM", -ob } },
    }
    local used = 0
    for row = 1, 3 do
        for column = 1, 3 do
            local active = (columns == 3 or column == 2) and (rows == 3 or row == 2)
                and not (self.hollow and columns == 3 and rows == 3 and row == 2 and column == 2)
            if active then
                used = used + 1
                local texture = self:Texture(used)
                texture:SetTexture(path)
                texture:SetTexCoord(us[column], us[column + 1], vs[row], vs[row + 1])
                texture:ClearAllPoints()
                local leftEdge, rightEdge = columnEdges[column][1], columnEdges[column][2]
                local topEdge, bottomEdge = rowEdges[row][1], rowEdges[row][2]
                texture:SetPoint("TOPLEFT", frame, topEdge[1] .. leftEdge[1], leftEdge[2], topEdge[2])
                texture:SetPoint("BOTTOMRIGHT", frame, bottomEdge[1] .. rightEdge[1], rightEdge[2], bottomEdge[2])
                if self.color then
                    texture:SetVertexColor(unpack(self.color))
                end
                if self.shown then
                    texture:Show()
                else
                    texture:Hide()
                end
            end
        end
    end
    for index = used + 1, #self.textures do
        self.textures[index]:Hide()
    end
    self.used = used
end

function Slice:SetPiece(name)
    local piece = Theme.Piece(name)
    if self.piece == piece then
        return
    end
    self.piece = piece
    self.pieceName = name
    self:Layout()
end

function Slice:SetVertexColor(r, g, b, a)
    self.color = { r, g, b, a or 1 }
    for index = 1, self.used or 0 do
        self.textures[index]:SetVertexColor(r, g, b, a or 1)
    end
end

function Slice:Show()
    self.shown = true
    for index = 1, self.used or 0 do
        self.textures[index]:Show()
    end
end

function Slice:Hide()
    self.shown = false
    for _, texture in ipairs(self.textures) do
        texture:Hide()
    end
end

--[[ Panels and section tabs ]]

-- The dark 9-slice box behind every block (list, source, preview, the
-- Button / Forms / State sections, the export text).
function Theme.CreatePanel(frame, layer)
    local slice = Theme.CreateSlice(frame, layer or "BACKGROUND")
    slice:SetPiece("panel")
    return slice
end

Theme.SECTION_TAB_HEIGHT = 18
local SECTION_TAB_PADDING_LEFT = 8
local SECTION_TAB_PADDING_RIGHT = 16 -- room for the arrow point
Theme.SECTION_TAB_PADDING = SECTION_TAB_PADDING_LEFT + SECTION_TAB_PADDING_RIGHT

-- A gold label tab ("TEMPLATE SOURCE"). Returns a frame with :SetText(text)
-- that sizes itself to the text, and again on every show: text measured
-- before the tab joined a window at another scale has another width.
function Theme.CreateSectionTab(parent)
    local tab = CreateFrame("Frame", nil, parent)
    tab:SetHeight(Theme.SECTION_TAB_HEIGHT)
    tab.slice = Theme.CreateSlice(tab, "BACKGROUND")
    tab.slice:SetPiece("section-tab")
    local text = tab:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    text:SetPoint("LEFT", tab, "LEFT", SECTION_TAB_PADDING_LEFT, 0)
    text:SetJustifyH("LEFT")
    text:SetTextColor(unpack(Theme.colors.tabText))
    if text.SetShadowOffset then
        text:SetShadowOffset(0, 0)
    end
    tab.text = text
    function tab:SetText(value)
        value = value and string.upper(value) or ""
        self.label = value
        self.text:SetText(value)
        local width = math.ceil(self.text:GetStringWidth() or 0)
        self:SetWidth(width + SECTION_TAB_PADDING_LEFT + SECTION_TAB_PADDING_RIGHT)
    end
    function tab:GetText()
        return self.label
    end
    tab:HookScript("OnShow", function(self)
        self:SetText(self.label)
    end)
    return tab
end

--[[ Scrollbars ]]

-- Re-arts a UIPanelScrollBarTemplate slider (track, thumb, arrows). The
-- slider must be ours (created by a WMC widget), never a pooled one.
Theme.SCROLLBAR_WIDTH = 16
function Theme.SkinScrollBar(slider, upButton, downButton)
    if not slider then
        return
    end
    slider:SetWidth(Theme.SCROLLBAR_WIDTH)
    if not slider.wmcTrack then
        local track = Theme.CreateSlice(slider, "BACKGROUND")
        track:SetPiece("scroll-track")
        slider.wmcTrack = track
    end
    local thumbPiece = Theme.Piece("scroll-thumb")
    if slider.SetThumbTexture then
        slider:SetThumbTexture(PATH .. thumbPiece[1])
        local thumb = slider.GetThumbTexture and slider:GetThumbTexture()
        if thumb and thumb.SetTexCoord then
            thumb:SetTexCoord(thumbPiece[2], thumbPiece[3], thumbPiece[4], thumbPiece[5])
            thumb:SetWidth(thumbPiece[6])
            thumb:SetHeight(thumbPiece[7])
            slider.wmcThumb = thumb
        end
    end
    if not slider.wmcHooked and slider.HookScript then
        slider.wmcHooked = true
        slider:HookScript("OnEnter", function(self)
            if self.wmcThumb then
                local piece = Theme.Piece("scroll-thumb-hover")
                self.wmcThumb:SetTexCoord(piece[2], piece[3], piece[4], piece[5])
            end
        end)
        slider:HookScript("OnLeave", function(self)
            if self.wmcThumb then
                local piece = Theme.Piece("scroll-thumb")
                self.wmcThumb:SetTexCoord(piece[2], piece[3], piece[4], piece[5])
            end
        end)
        if slider.EnableMouse then
            slider:EnableMouse(true)
        end
    end
    for _, entry in ipairs({ { upButton, "scroll-up" }, { downButton, "scroll-down" } }) do
        local button, prefix = entry[1], entry[2]
        if button then
            button:SetWidth(Theme.SCROLLBAR_WIDTH)
            button:SetHeight(Theme.SCROLLBAR_WIDTH)
            Theme.SetButtonPiece(button, "Normal", prefix .. "-normal")
            Theme.SetButtonPiece(button, "Pushed", prefix .. "-pressed")
            Theme.SetButtonPiece(button, "Disabled", prefix .. "-disabled")
            Theme.SetButtonPiece(button, "Highlight", prefix .. "-hover")
        end
    end
end

-- A text area (TextArea.lua) keeps its scrollbar OUTSIDE its box, in a
-- column at its right: gap + bar + a small margin. Every other full-width
-- block of the editor (the Button / Forms / State sections) stops the same
-- distance short of the right edge, so all boxes share one left and one
-- right edge whether or not a text area's bar is showing.
Theme.TEXTAREA_BAR_GAP = 4
Theme.TEXTAREA_BAR_MARGIN = 2
Theme.BOX_RIGHT_INSET = Theme.TEXTAREA_BAR_GAP + Theme.SCROLLBAR_WIDTH + Theme.TEXTAREA_BAR_MARGIN

-- The two global-name lookups a UIPanelScrollBarTemplate slider needs.
function Theme.ScrollBarButtons(slider)
    local name = slider and slider.GetName and slider:GetName()
    if not name then
        return nil, nil
    end
    return _G[name .. "ScrollUpButton"], _G[name .. "ScrollDownButton"]
end

--[[ Window frames ]]

-- Windows in the popup look instead of a frame (popup style A, as the
-- dialogs and the icon picker: the thin panel, the gold label tab with the
-- title, which is also the drag handle, and a shadow; no X, a Close button
-- at the bottom instead): their size and content insets. The export /
-- import window's content is as big as in the pipe frame it had (500 x 348).
Theme.POPUP_FRAMES = {
    text = { width = 528, height = 388, insets = { left = 14, right = 14, top = 26, bottom = 14 } },
}
Theme.POPUP_RIM = 5                     -- the panel art's rim
Theme.POPUP_TAB_MARGIN = 40             -- kept clear right of the title tab

-- Content insets inside each window frame (units from the window's edge):
-- clear of the pipes. The main window's editor column starts lower, under
-- the hanging title plaque (Theme.EditorTop). Its right one keeps the
-- editor's scrollbar 4 units clear of the column's lower half (its left
-- side is at 931).
Theme.CONTENT_INSETS = {
    main = { left = 30, right = 33, top = 32, bottom = 28 },
    -- Quintessence Macros: its own frame, the band's inner edges at 15 and
    -- 930: 20 from the content on each side, as its two columns are from
    -- each other (19)
    bank = { left = 35, right = 35, top = 32, bottom = 28 },
}

-- How far each corner's art reaches into the content area, in units from
-- the content area's matching edge, measured over the content's outermost
-- 24 units (a scrollbar's column). The bottom-right gear housing overlaps
-- the editor's scrollbar column; bars there end this far above the bottom.
-- Art-dependent: re-measure after changing the corners (frame preview
-- alpha > 32 over those columns). bottomLeft is the valve wheel on the left
-- pipe, which pokes 2 units into the content's left edge.
Theme.CORNER_CLEAR = {
    main = { topLeft = 9, topRight = 10, bottomLeft = 47, bottomRight = 11 },
    -- (its corner plates stay clear of the content: measured)
    bank = { topLeft = 0, topRight = 0, bottomLeft = 0, bottomRight = 0 },
}
-- Extra space between a scrollbar's end and the corner art.
Theme.CORNER_GAP = 2

-- Units a scrollbar ending at the content area's bottom-right corner must
-- stop short of it.
function Theme.BarBottomClearance(style)
    local clear = Theme.CORNER_CLEAR[style]
    local amount = clear and clear.bottomRight or 0
    return amount > 0 and (amount + Theme.CORNER_GAP) or 0
end

function Theme.FrameData(style)
    return data.frames[style]
end

-- Units the frame art rises above the window's top edge (the title plaque
-- and its crest), which the window's screen clamp has to include.
function Theme.ArtAbove(style)
    local frameData = data.frames[style]
    local top = frameData.plaque[2]
    for _, tile in ipairs(frameData.crest or {}) do
        top = math.min(top, tile[7])
    end
    -- a column as the right edge: its cap (its smoke may leave the screen)
    return math.max(0, -top, frameData.above or 0)
end

-- Units from the sidebar's top (UI.lua) to the editor column: its heading's
-- plate (32 tall in a 34 tall row, its art 1 unit in) lines up with the
-- sidebar's first field (the class dropdown, under its 18 unit label, its
-- art 1 unit in). The title plaque's lowest art (its tube caps) ends just
-- above it.
Theme.EDITOR_TOP = 17
function Theme.EditorTop(style)
    return Theme.EDITOR_TOP
end

-- Builds the static art of a window frame: a non-interactive layer over the
-- window (level + 20, above its content and above the close button, so the
-- housing's rim overlaps the button's edge). A style may add side art over
-- the frame tiles (level + 21) with the close-button housing redrawn over
-- that (level + 22), so the art runs on behind the housing. Each sits on its
-- own frame: draw sublevels within one frame did not reliably keep the side
-- art above the tiles in the client (the window's pipe sometimes covered the
-- side art's gear until a reload); frame levels always order. Returns the
-- art frame.
Theme.FRAME_ART_LEVELS = 3 -- levels above the art frame's own that its layers use
function Theme.BuildFrameArt(frame, style)
    local frameData = data.frames[style]
    local art = CreateFrame("Frame", nil, frame)
    art:SetAllPoints(frame)
    art:SetFrameLevel(frame:GetFrameLevel() + 20)
    local function place(tiles, offset, drawLayer)
        local textures = {}
        local layer = art
        if tiles and offset > 0 then
            layer = CreateFrame("Frame", nil, art)
            layer:SetAllPoints(art)
            layer:SetFrameLevel(art:GetFrameLevel() + offset)
        end
        for index, tile in ipairs(tiles or {}) do
            local file, l, r, t, b, x, y, w, h = unpack(tile)
            local texture = layer:CreateTexture(nil, drawLayer or "ARTWORK")
            texture:SetTexture(PATH .. file)
            texture:SetTexCoord(l, r, t, b)
            texture:SetWidth(w)
            texture:SetHeight(h)
            texture:SetPoint("TOPLEFT", frame, "TOPLEFT", x, -y)
            textures[index] = texture
        end
        return textures
    end
    art.tiles = place(frameData.tiles, 0)
    art.side = place(frameData.side, 1)
    -- An ornament on the title plate (none at the moment), drawn over the
    -- frame tiles like the side art.
    art.crest = place(frameData.crest, 1)
    art.housing = place(frameData.housing, 2)
    -- The modal veil's darkening (Theme.DimFrame): the art is tinted, and
    -- this shade, under the art, darkens the inside. Its edges run along
    -- the pipes' centrelines (and up to the close-button opening's top), so
    -- it never shows outside the frame's outline.
    local inset = frameData.inset
    local hx0, hy0, hx1, hy1 = unpack(frameData.hole)
    -- With a column as the right edge (frameData.inside) the inside ends
    -- behind the column's spine, and its socket's opening rises well above
    -- the top pipe: the shade stays on the pipe's centreline there.
    local right = frameData.inside or (frameData.width - inset)
    local top = frameData.inside and inset or math.min(inset, math.floor(hy0))
    local function addShade(x0, y0, x1, y1)
        local shade = art:CreateTexture(nil, "BACKGROUND")
        shade:SetTexture(0, 0, 0, 1)
        shade:SetVertexColor(0, 0, 0, Theme.VEIL_ALPHA)
        shade:SetPoint("TOPLEFT", frame, "TOPLEFT", x0, -y0)
        shade:SetPoint("BOTTOMRIGHT", frame, "TOPLEFT", x1, -y1)
        shade:Hide()
        table.insert(art.shades, shade)
    end
    art.shades = {}
    addShade(inset, top, right, frameData.height - inset)
    -- The close-button opening reaches past the shade (the right pipe's
    -- centreline; a column's socket also above the top pipe's): the rest
    -- of it gets shades of its own, never overlapping the first (the
    -- button sits under the art, seen only through the opening).
    if math.floor(hy0) < top then
        addShade(math.floor(hx0), math.floor(hy0), math.ceil(hx1) + 1, top)
    end
    if hx1 > right then
        addShade(right, math.max(top, math.floor(hy0)), math.ceil(hx1) + 1, math.ceil(hy1))
    end
    frame.wmcArts = frame.wmcArts or {}
    table.insert(frame.wmcArts, art)
    return art
end

-- Darkens a themed window (its frame art, the inside, and the frames listed
-- in frame.wmcDimFrames, such as the title) while a modal popup's veil is
-- over it, following the frame's outline instead of its rectangle. Calls
-- nest: the window stays dark until every `true` has had its `false`.
function Theme.DimFrame(frame, dimmed)
    frame.wmcDimCount = math.max(0, (frame.wmcDimCount or 0) + (dimmed and 1 or -1))
    local on = frame.wmcDimCount > 0
    local tint = on and 1 - Theme.VEIL_ALPHA or 1
    for _, art in ipairs(frame.wmcArts or {}) do
        for _, shade in ipairs(art.shades) do
            if on then shade:Show() else shade:Hide() end
        end
        for _, list in ipairs({ art.tiles, art.side, art.crest, art.housing }) do
            for _, texture in ipairs(list) do
                texture:SetVertexColor(tint, tint, tint)
            end
        end
    end
    for _, extra in ipairs(frame.wmcDimFrames or {}) do
        extra:SetAlpha(tint)
    end
end

--[[ Background ]]

-- The dark-iron texture, laid as a grid of BACKGROUND_TILE-unit textures
-- from a rectangle's top-left corner. Not a tiled backdrop: a backdrop
-- tiles by texture coordinates above 1, and the 3.3.5 client clamps those
-- vertically instead of wrapping (the last texel row is smeared down into
-- vertical bars). Each texture here shows at most one whole copy; the last
-- column and row are cropped with coordinates <= 1.
Theme.BACKGROUND_TILE = 256

local Background = {}
Background.__index = Background

function Theme.CreateBackground(frame, layer, subLevel)
    return setmetatable({ frame = frame, layer = layer or "BACKGROUND", subLevel = subLevel or -8,
        textures = {}, used = 0 }, Background)
end

-- Fills the rectangle `width` x `height` whose top-left corner is `left`,
-- `top` units right of and below the frame's top-left corner.
function Background:Layout(left, top, width, height)
    local size = Theme.BACKGROUND_TILE
    local path = PATH .. data.background
    width, height = math.max(0, math.floor(width)), math.max(0, math.floor(height))
    local used = 0
    for y = 0, height - 1, size do
        local h = math.min(size, height - y)
        for x = 0, width - 1, size do
            local w = math.min(size, width - x)
            used = used + 1
            local texture = self.textures[used]
            if not texture then
                texture = self.frame:CreateTexture(nil, self.layer)
                if texture.SetDrawLayer then
                    texture:SetDrawLayer(self.layer, self.subLevel)
                end
                self.textures[used] = texture
            end
            texture:SetTexture(path)
            texture:SetTexCoord(0, w / size, 0, h / size)
            texture:ClearAllPoints()
            texture:SetPoint("TOPLEFT", self.frame, "TOPLEFT", left + x, -(top + y))
            texture:SetWidth(w)
            texture:SetHeight(h)
            texture:Show()
        end
    end
    for index = used + 1, #self.textures do
        self.textures[index]:Hide()
    end
    self.used = used
    self.rect = { left, top, width, height }
end

function Background:Hide()
    for _, texture in ipairs(self.textures) do
        texture:Hide()
    end
end

-- The tiled dark-iron interior of a window, inset to the pipes' centre
-- lines (the window has a fixed size per style).
function Theme.ApplyBackground(frame, style)
    local frameData = data.frames[style]
    local inset = frameData.inset
    if frame.SetBackdrop then
        frame:SetBackdrop(nil) -- an older build's tiled backdrop
    end
    frame.wmcBackground = frame.wmcBackground or Theme.CreateBackground(frame)
    -- (with a column as the right edge: to behind its spine, frameData.inside)
    frame.wmcBackground:Layout(inset, inset, (frameData.inside or (frameData.width - inset)) - inset, frameData.height - 2 * inset)
    return frame.wmcBackground
end

--[[ Popup look ]]

-- A soft drop shadow around `frame`: stacked translucent black layers,
-- each a little larger and fainter (no art needed). `spread` units wide,
-- shifted `dx`, `dy` (down-right) like a light from the top-left.
Theme.SHADOW_SPREAD = 24
Theme.SHADOW_OFFSET = 4
Theme.SHADOW_ALPHA = 0.11

function Theme.CreateShadow(frame, spread, dx, dy)
    spread = spread or Theme.SHADOW_SPREAD
    dx = dx or Theme.SHADOW_OFFSET
    dy = dy or Theme.SHADOW_OFFSET
    local layers = {}
    local steps = math.max(1, math.floor(spread / 2))
    for step = 1, steps do
        local outset = step * 2
        local texture = frame:CreateTexture(nil, "BACKGROUND")
        if texture.SetDrawLayer then
            texture:SetDrawLayer("BACKGROUND", -8)
        end
        texture:SetTexture(0, 0, 0, 1)
        -- Inner layers stack up darkest; the outer ones fade out.
        local fade = 1 - (step - 1) / steps
        texture:SetVertexColor(0, 0, 0, Theme.SHADOW_ALPHA * fade)
        texture:SetPoint("TOPLEFT", frame, "TOPLEFT", -outset + dx, outset - dy)
        texture:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", outset + dx, -outset - dy)
        layers[step] = texture
    end
    return layers
end

-- The dark veil over a window while a modal popup is open.
Theme.VEIL_ALPHA = 0.55

-- Rectangle helpers: data rects are { x0, y0, x1, y1 } in units from the
-- window's top-left, y down.
function Theme.Rect(style, field)
    return unpack(data.frames[style][field])
end
