-- Options/UIKit.lua : the reusable, panel-agnostic UI toolkit, exposed as ns.UI.
--
-- Extracted from Panel.lua so the settings code stays navigable and these widgets
-- are reusable by any future file. NOTHING here touches panel state (P, the profile)
-- — only WoW APIs plus the ACCENT/COL tokens. Panel.lua re-localizes each of these
-- (local Button = ns.UI.Button, …) so its call sites are unchanged.

local ADDON, ns = ...

local UI = {}
ns.UI = UI

-- All styling values come from the theme (Core/Theme.lua). ACCENT + COL are aliased
-- for terse call sites; everything else reads T.* below.
local T = ns.Theme
local ACCENT = T.accent

-- ── tiny UI toolkit ───────────────────────────────────────────────────
local function border(f, a)
    local e = {}
    for _, k in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
        local t = f:CreateTexture(nil, "BORDER"); t:SetColorTexture(T.surface.edge[1], T.surface.edge[2], T.surface.edge[3], a or 1); e[k] = t
    end
    e.TOP:SetPoint("TOPLEFT"); e.TOP:SetPoint("TOPRIGHT"); e.TOP:SetHeight(1)
    e.BOTTOM:SetPoint("BOTTOMLEFT"); e.BOTTOM:SetPoint("BOTTOMRIGHT"); e.BOTTOM:SetHeight(1)
    e.LEFT:SetPoint("TOPLEFT"); e.LEFT:SetPoint("BOTTOMLEFT"); e.LEFT:SetWidth(1)
    e.RIGHT:SetPoint("TOPRIGHT"); e.RIGHT:SetPoint("BOTTOMRIGHT"); e.RIGHT:SetWidth(1)
    return e
end

local function bgTex(f, r, g, b, a)
    local t = f:CreateTexture(nil, "BACKGROUND"); t:SetAllPoints(f); t:SetColorTexture(r, g, b, a or 1); return t
end

-- COL: the three surfaces used all over the toolkit, aliased from the theme so
-- existing COL.ctrl / COL.muted / COL.panel call sites are unchanged.
local COL = {
    ctrl  = T.surface.control,
    muted = T.text.muted,
    panel = T.surface.form,
}

-- ── Tiny tween engine ─────────────────────────────────────────────────
-- One shared OnUpdate lerps all short UI animations (hover fades, glints). Each
-- tween self-removes on completion and the driver hides when idle, so there is no
-- steady per-frame cost. WoW gives us frame dt directly — no timestamps needed.
local _tweens = {}
local _tweenDriver = CreateFrame("Frame"); _tweenDriver:Hide()
_tweenDriver:SetScript("OnUpdate", function(self, dt)
    local any = false
    for t in pairs(_tweens) do
        any = true
        t.e = t.e + dt
        local k = t.e / t.d; if k > 1 then k = 1 end
        t.step(k)
        if k >= 1 then _tweens[t] = nil end
    end
    if not any then self:Hide() end
end)
-- Fade a texture/region's alpha toward `to` over `dur` seconds (cancels any prior
-- fade on it). dur 0 / tiny delta -> snap.
local function tweenAlpha(reg, to, dur)
    if reg._tw then _tweens[reg._tw] = nil; reg._tw = nil end
    local from = reg:GetAlpha()
    if not (dur and dur > 0) or math.abs(to - from) < 0.008 then reg:SetAlpha(to); return end
    local t = { e = 0, d = dur, step = function(k) reg:SetAlpha(from + (to - from) * k) end }
    reg._tw = t; _tweens[t] = true; _tweenDriver:Show()
end

local function Label(parent, text, font)
    local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
    fs:SetText(text); return fs
end

-- A flat control button. Resting fill + an accent highlight whose ALPHA fades on
-- hover / hold, and stays lit when SetActive(true) — so hover, press and toggle
-- state all read from one animated layer (no colour snapping).
local function Button(parent, text, w, h)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(w or 80, h or 22)
    b._bg = bgTex(b, COL.ctrl[1], COL.ctrl[2], COL.ctrl[3])
    b._hl = b:CreateTexture(nil, "ARTWORK"); b._hl:SetAllPoints(); b._hl:SetColorTexture(ACCENT[1], ACCENT[2], ACCENT[3], 1); b._hl:SetAlpha(0)
    border(b)
    local fs = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight"); fs:SetPoint("CENTER"); fs:SetText(text); b._fs = fs
    local function base() return b._on and T.fx.activeAlpha or 0 end
    b:SetScript("OnEnter", function() tweenAlpha(b._hl, base() + T.fx.hoverAlpha, T.fx.hover) end)
    b:SetScript("OnLeave", function() tweenAlpha(b._hl, base(), T.fx.leave) end)
    b:HookScript("OnMouseDown", function() b._hl:SetAlpha(base() + T.fx.pressAlpha) end)
    b:HookScript("OnMouseUp", function() tweenAlpha(b._hl, b:IsMouseOver() and (base() + T.fx.hoverAlpha) or base(), T.fx.press) end)
    b.SetActive = function(_, on) b._on = on and true or false; tweenAlpha(b._hl, b:IsMouseOver() and (base() + T.fx.hoverAlpha) or base(), T.fx.hover) end
    return b
end

-- Custom checkbox: a box that fills with accent + a check when on, with a soft
-- hover — cleaner and on-theme vs the default Blizzard template. Keeps the same
-- SetChecked/GetChecked the callers use.
local function Check(parent, label, onChange)
    local c = CreateFrame("Button", nil, parent)
    c:SetSize(20, 20)
    c._bg = bgTex(c, COL.ctrl[1], COL.ctrl[2], COL.ctrl[3])
    c._hl = c:CreateTexture(nil, "ARTWORK"); c._hl:SetAllPoints(); c._hl:SetColorTexture(ACCENT[1], ACCENT[2], ACCENT[3], 1); c._hl:SetAlpha(0)
    border(c)
    c._fill = c:CreateTexture(nil, "ARTWORK"); c._fill:SetPoint("TOPLEFT", 2, -2); c._fill:SetPoint("BOTTOMRIGHT", -2, 2)
    c._fill:SetColorTexture(ACCENT[1], ACCENT[2], ACCENT[3], 1); c._fill:SetAlpha(0)
    c._check = c:CreateTexture(nil, "OVERLAY"); c._check:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
    c._check:SetVertexColor(1, 1, 1); c._check:SetAllPoints(); c._check:SetAlpha(0)
    local fs = c:CreateFontString(nil, "OVERLAY", "GameFontHighlight"); fs:SetPoint("LEFT", c, "RIGHT", 6, 0); fs:SetText(label); c._fs = fs
    c.SetChecked = function(_, on)
        c._checked = on and true or false
        c._fill:SetAlpha(c._checked and 0.85 or 0); c._check:SetAlpha(c._checked and 1 or 0)
    end
    c.GetChecked = function() return c._checked end
    c:SetScript("OnEnter", function() tweenAlpha(c._hl, T.fx.checkAlpha, T.fx.hover) end)
    c:SetScript("OnLeave", function() tweenAlpha(c._hl, 0, T.fx.leave) end)
    c:SetScript("OnClick", function() c:SetChecked(not c._checked); if onChange then onChange(c._checked) end end)
    return c
end

local function Slider(parent, min, max, step, width, onChange)
    local s = CreateFrame("Slider", nil, parent)
    s:SetSize(width or 150, 16)
    s:SetOrientation("HORIZONTAL")
    s:SetMinMaxValues(min, max); s:SetValueStep(step or 1); s:SetObeyStepOnDrag(true)
    local track = s:CreateTexture(nil, "BACKGROUND"); track:SetColorTexture(T.rgba(T.surface.sliderTrack))
    track:SetPoint("LEFT"); track:SetPoint("RIGHT"); track:SetHeight(5)
    local fill = s:CreateTexture(nil, "ARTWORK"); fill:SetColorTexture(ACCENT[1], ACCENT[2], ACCENT[3], 0.6)
    fill:SetPoint("LEFT", track, "LEFT"); fill:SetHeight(5); fill:SetWidth(1)   -- accent fill up to the thumb
    local thumb = s:CreateTexture(nil, "OVERLAY"); thumb:SetColorTexture(T.text.thumb[1], T.text.thumb[2], T.text.thumb[3]); thumb:SetSize(8, 16)
    s:SetThumbTexture(thumb)
    local val = s:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); val:SetPoint("LEFT", s, "RIGHT", 8, 0); s._val = val
    local function setFill(v)
        local lo, hi = s:GetMinMaxValues()
        local frac = (hi > lo) and ((v - lo) / (hi - lo)) or 0
        fill:SetWidth(math.max(1, (width or 150) * math.max(0, math.min(1, frac))))
    end
    s:SetScript("OnValueChanged", function(_, v)
        v = math.floor(v + 0.5); val:SetText(v); setFill(v)
        if s._live and onChange then onChange(v) end
    end)
    s:SetScript("OnEnter", function() thumb:SetColorTexture(1, 1, 1) end)
    s:SetScript("OnLeave", function() thumb:SetColorTexture(T.text.thumb[1], T.text.thumb[2], T.text.thumb[3]) end)
    s.Set = function(_, v) s._live = false; s:SetValue(v or min); s._val:SetText(math.floor((v or min) + 0.5)); setFill(v or min); s._live = true end

    -- Click the value to TYPE an exact number, so a precise setting doesn't mean
    -- hunting for the pixel on the track. A hidden field overlays the value on click;
    -- Enter / focus-out clamps to range and applies (which fires onChange like a drag).
    local eb = CreateFrame("EditBox", nil, s)
    eb:SetAutoFocus(false); eb:SetFontObject("GameFontHighlightSmall")
    eb:SetSize(44, 16); eb:SetPoint("LEFT", s, "RIGHT", 6, 0); eb:SetJustifyH("LEFT")
    eb:SetTextColor(1, 1, 1); eb:Hide()
    local function commitEB()
        local n = tonumber(eb:GetText())
        eb:Hide(); val:Show()
        if n then
            n = math.max(min, math.min(max, n))
            s._live = true; s:SetValue(n)   -- snaps to step + fires OnValueChanged -> onChange
        end
    end
    eb:SetScript("OnEnterPressed", function() commitEB(); eb:ClearFocus() end)
    eb:SetScript("OnEscapePressed", function() eb:Hide(); val:Show(); eb:ClearFocus() end)
    eb:SetScript("OnEditFocusLost", commitEB)
    local hit = CreateFrame("Button", nil, s)
    hit:SetPoint("LEFT", s, "RIGHT", 4, 0); hit:SetSize(46, 16)
    hit:SetScript("OnClick", function()
        val:Hide()
        eb:SetText(tostring(math.floor(s:GetValue() + 0.5)))
        eb:Show(); eb:SetFocus(); eb:HighlightText()
    end)
    hit:SetScript("OnEnter", function() val:SetTextColor(ACCENT[1], ACCENT[2], ACCENT[3]) end)
    hit:SetScript("OnLeave", function() val:SetTextColor(1, 1, 1) end)
    return s
end

-- A flat, on-theme text field: dark fill + 1px border, with the border going accent
-- (and the fill lifting) while it's focused. Our own look instead of Blizzard's
-- InputBoxTemplate, so every input matches the panel. The focus visuals are HOOKED
-- (not SetScript) so they survive callers that replace OnEditFocusLost.
local function EditBox(parent, width, onChange)
    local e = CreateFrame("EditBox", nil, parent)
    e:SetSize(width or 160, 20); e:SetAutoFocus(false); e:SetFontObject("GameFontHighlight")
    e:SetTextInsets(6, 6, 0, 0)
    e._bg = bgTex(e, COL.ctrl[1], COL.ctrl[2], COL.ctrl[3])
    local edge = border(e)
    local function setEdge(r, g, b)
        edge.TOP:SetColorTexture(r, g, b, 1); edge.BOTTOM:SetColorTexture(r, g, b, 1)
        edge.LEFT:SetColorTexture(r, g, b, 1); edge.RIGHT:SetColorTexture(r, g, b, 1)
    end
    e:SetScript("OnEscapePressed", function() e:ClearFocus() end)
    e:SetScript("OnEnterPressed", function() e:ClearFocus() end)
    e:SetScript("OnEditFocusLost", function() if onChange then onChange(e:GetText()) end end)
    e:HookScript("OnEditFocusGained", function() setEdge(ACCENT[1], ACCENT[2], ACCENT[3]); e._bg:SetColorTexture(T.surface.controlFocus[1], T.surface.controlFocus[2], T.surface.controlFocus[3]) end)
    e:HookScript("OnEditFocusLost", function() setEdge(T.surface.edge[1], T.surface.edge[2], T.surface.edge[3]); e._bg:SetColorTexture(COL.ctrl[1], COL.ctrl[2], COL.ctrl[3]) end)
    return e
end

-- A shared "item field": type an item id (or "item:NNN"), or shift-click an item in while the box
-- has focus. ONE HandleModifiedItemClick hook serves every item field, routed by which box currently
-- has focus — instead of a separate hooksecurefunc per field. onSet(idOrNil) stores the id (typed or
-- shift-clicked). Returns the box; its confirmation icon is box._icon.
local itemFields, itemHooked = {}, false
local function ItemField(parent, width, onSet)
    local box = EditBox(parent, width, function(t)
        local id = t and (t:match("item:(%d+)") or t:match("^%s*(%d+)%s*$"))
        onSet(id and tonumber(id) or nil)
    end)
    local icon = box:CreateTexture(nil, "OVERLAY")
    icon:SetSize(16, 16); icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    icon:SetPoint("LEFT", box, "LEFT", 4, 0); icon:Hide()
    box._icon = icon
    itemFields[#itemFields + 1] = { box = box, onSet = onSet }
    if not itemHooked then
        itemHooked = true
        hooksecurefunc("HandleModifiedItemClick", function(link)
            if not link then return end
            for _, f in ipairs(itemFields) do
                if f.box:HasFocus() then
                    local id = tostring(link):match("item:(%d+)")
                    if id then f.box:SetText("item:" .. id); f.onSet(tonumber(id)) end
                    return
                end
            end
        end)
    end
    return box
end

-- Dropdown: a button that drops a scrollable list of { value=, text= } items.
-- opts.kind = "font"   -> each row is drawn IN that font (live preview)
--             "texture"-> each row shows a preview swatch of that bar texture
-- The menu is wider than the button (long LSM names) and shows a scrollbar
-- thumb whenever the list overflows, so it's obvious you can scroll.
-- ── Interactive scrollbar ─────────────────────────────────────────────
-- A draggable thumb + click-to-jump track, shown only on overflow. Abstracted over the
-- scroll SOURCE via cb so it fits both a ScrollFrame (pixel scroll) and the dropdown
-- (row offset): cb.getMax() (0 = no overflow), cb.get()/cb.set(v), cb.frac() (visible /
-- total = the thumb's size). `anchorTo` gives the height + right edge; `parent` hosts the
-- bar (kept OUTSIDE a clipping scroll child so it isn't scrolled/clipped). Returns an
-- update() to reposition the thumb after the content changes.
local function MakeScrollbar(parent, anchorTo, cb)
    local bar = CreateFrame("Frame", nil, parent)
    bar:SetPoint("TOPRIGHT", anchorTo, "TOPRIGHT", 0, 0)
    bar:SetPoint("BOTTOMRIGHT", anchorTo, "BOTTOMRIGHT", 0, 0)
    bar:SetWidth(10)
    bar:SetFrameLevel(anchorTo:GetFrameLevel() + 25)

    local track = CreateFrame("Button", nil, bar)
    track:SetPoint("TOPRIGHT", -1, -3); track:SetPoint("BOTTOMRIGHT", -1, 3); track:SetWidth(8)
    local tTex = track:CreateTexture(nil, "ARTWORK"); tTex:SetColorTexture(1, 1, 1, 0.06)
    tTex:SetPoint("TOPRIGHT", -1, 0); tTex:SetPoint("BOTTOMRIGHT", -1, 0); tTex:SetWidth(4)
    track:Hide()

    local thumb = CreateFrame("Button", nil, track)
    thumb:SetPoint("RIGHT", -1, 0); thumb:SetWidth(4)
    local hTex = thumb:CreateTexture(nil, "OVERLAY"); hTex:SetAllPoints()
    local function paint(a) hTex:SetColorTexture(ACCENT[1], ACCENT[2], ACCENT[3], a) end
    paint(0.7)

    local function geo()
        local maxOff = cb.getMax() or 0
        local trackH = math.max(1, anchorTo:GetHeight() - 6)
        local f = cb.frac() or 1; if f > 1 then f = 1 end
        local thumbH = math.max(20, trackH * f); if thumbH > trackH then thumbH = trackH end
        return maxOff, trackH, thumbH
    end
    local function update()
        local maxOff, trackH, thumbH = geo()
        if maxOff <= 0 then                          -- content now fits: park at top, hide
            if (cb.get() or 0) ~= 0 then cb.set(0) end
            track:Hide(); return
        end
        if cb.get() > maxOff then cb.set(maxOff) end  -- content shrank: pull scroll back in
        track:Show()
        local frac = (maxOff > 0) and (cb.get() / maxOff) or 0
        frac = (frac < 0 and 0) or (frac > 1 and 1) or frac
        thumb:SetHeight(thumbH)
        thumb:ClearAllPoints()
        thumb:SetPoint("TOP", track, "TOP", 0, -frac * (trackH - thumbH)); thumb:SetPoint("RIGHT", -1, 0)
    end

    thumb:EnableMouse(true)
    thumb:SetScript("OnEnter", function() paint(0.95) end)
    thumb:SetScript("OnLeave", function() if not thumb._drag then paint(0.7) end end)
    thumb:SetScript("OnMouseDown", function()
        thumb._drag = true
        local _, cy = GetCursorPosition(); thumb._cy = cy; thumb._off = cb.get()
    end)
    thumb:SetScript("OnMouseUp", function() thumb._drag = false; paint(0.7) end)
    bar:SetScript("OnUpdate", function()
        if not thumb._drag then return end
        if not IsMouseButtonDown("LeftButton") then thumb._drag = false; paint(0.7); return end
        local maxOff, trackH, thumbH = geo()
        local travel = trackH - thumbH
        if travel <= 0 or maxOff <= 0 then return end
        local scale = bar:GetEffectiveScale(); if not scale or scale <= 0 then scale = 1 end
        local _, cy = GetCursorPosition()
        local dy = (thumb._cy - cy) / scale                      -- cursor down -> scroll down
        cb.set(thumb._off + (dy / travel) * maxOff); update()
    end)
    -- Click the track (outside the thumb) to jump the thumb to that spot.
    track:SetScript("OnMouseDown", function()
        local maxOff, trackH, thumbH = geo()
        local travel = trackH - thumbH
        if travel <= 0 or maxOff <= 0 then return end
        local scale = track:GetEffectiveScale(); if not scale or scale <= 0 then scale = 1 end
        local _, cy = GetCursorPosition(); cy = cy / scale
        local top = track:GetTop(); if not top then return end
        local p = (top - cy) - thumbH / 2
        p = (p < 0 and 0) or (p > travel and travel) or p
        cb.set((p / travel) * maxOff); update()
    end)
    return update
end
UI.MakeScrollbar = MakeScrollbar

local openMenu
local DD_ROWS   = 12   -- visible rows before scrolling
local DD_ROW_H  = 20
local function Dropdown(parent, width, onSelect, opts)
    opts = opts or {}
    local kind = opts.kind
    local d = Button(parent, "", width or 150, 22)
    d._fs:ClearAllPoints(); d._fs:SetPoint("LEFT", 8, 0); d._fs:SetPoint("RIGHT", -18, 0)
    d._fs:SetJustifyH("LEFT"); d._fs:SetWordWrap(false)
    local arrow = d:CreateFontString(nil, "OVERLAY", "GameFontHighlight"); arrow:SetPoint("RIGHT", -6, 0); arrow:SetText("v")

    local menuW = math.max(width or 150, opts.menuWidth or (kind and 230) or 0)
    -- Parent the popup to UIParent (not the button) so it floats ABOVE the editor's
    -- scroll viewport instead of being clipped by it. It still anchors to the button,
    -- so it tracks position; a hide hook closes it if the button scrolls away/hides.
    local menu = CreateFrame("Frame", nil, UIParent)
    menu:SetFrameStrata("FULLSCREEN_DIALOG")
    menu:SetClipsChildren(true)
    bgTex(menu, T.rgba(T.surface.panel)); border(menu)
    menu:SetPoint("TOPLEFT", d, "BOTTOMLEFT", 0, -2)
    menu:SetWidth(menuW)
    menu:Hide()
    d:HookScript("OnHide", function() menu:Hide(); if openMenu == menu then openMenu = nil end end)
    d._menu, d._rows, d._items, d._offset = menu, {}, {}, 0

    -- Interactive scrollbar (draggable thumb + click-to-jump), mapped onto the row offset.
    local layout   -- forward-declared; the scrollbar's set() re-lays the rows
    local ddScroll = MakeScrollbar(menu, menu, {
        getMax = function() return math.max(0, #d._items - DD_ROWS) end,
        get    = function() return d._offset end,
        set    = function(v)
            local m = math.max(0, #d._items - DD_ROWS)
            d._offset = math.max(0, math.min(m, math.floor(v + 0.5)))
            layout()
        end,
        frac   = function() local n = #d._items; return (n > 0) and math.min(1, DD_ROWS / n) or 1 end,
    })

    local function decorate(r, item)
        r._val = item.value
        r._f:SetText(item.text)
        if kind == "font" then
            if not r._f:SetFont(ns.Media.Font(item.value), 14, "") then r._f:SetFontObject("GameFontHighlight") end
            if r._preview then r._preview:Hide() end
        elseif kind == "texture" then
            r._f:SetFontObject("GameFontHighlight")
            if not r._preview then
                local pv = r:CreateTexture(nil, "ARTWORK")
                pv:SetPoint("LEFT", r, "LEFT", 118, 0); pv:SetPoint("RIGHT", r, "RIGHT", -4, 0); pv:SetHeight(12)
                r._preview = pv
            end
            r._preview:SetTexture(ns.Media.Bar(item.value))
            r._preview:SetVertexColor(0.35, 0.60, 0.95, 1)
            r._preview:Show()
        else
            r._f:SetFontObject("GameFontHighlight")
        end
    end

    function layout()
        local n = #d._items
        local vis = math.min(n, DD_ROWS)
        local h = math.max(1, vis) * DD_ROW_H + 2
        menu:SetHeight(h)
        for i = 1, DD_ROWS do
            local r = d._rows[i]
            if not r then break end
            local item = d._items[i + d._offset]
            if item and i <= vis then decorate(r, item); r:Show() else r:Hide() end
        end
        ddScroll()   -- reposition / show-hide the draggable thumb
    end

    menu:EnableMouseWheel(true)
    menu:SetScript("OnMouseWheel", function(_, delta)
        local maxOff = math.max(0, #d._items - DD_ROWS)
        d._offset = math.max(0, math.min(maxOff, d._offset - delta))
        layout()
    end)

    d.SetItems = function(_, items)
        d._items = items or {}
        d._offset = 0
        for i = 1, math.min(#d._items, DD_ROWS) do
            local r = d._rows[i]
            if not r then
                r = CreateFrame("Button", nil, menu); r:SetHeight(DD_ROW_H)
                r:SetPoint("TOPLEFT", 1, -((i - 1) * DD_ROW_H + 1))
                r:SetPoint("TOPRIGHT", -6, -((i - 1) * DD_ROW_H + 1))   -- gutter clears the scrollbar
                r._h = bgTex(r, ACCENT[1], ACCENT[2], ACCENT[3], 0)
                r._f = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight"); r._f:SetPoint("LEFT", 8, 0)
                r._f:SetJustifyH("LEFT"); r._f:SetWordWrap(false)
                if kind == "texture" then r._f:SetPoint("RIGHT", r, "LEFT", 114, 0) else r._f:SetPoint("RIGHT", -8, 0) end
                r:SetScript("OnEnter", function() r._h:SetColorTexture(ACCENT[1], ACCENT[2], ACCENT[3], T.fx.menuAlpha); if opts.onHover then opts.onHover(r._val) end end)
                r:SetScript("OnLeave", function() r._h:SetColorTexture(ACCENT[1], ACCENT[2], ACCENT[3], 0) end)
                r:SetScript("OnClick", function() menu:Hide(); openMenu = nil; onSelect(r._val) end)
                d._rows[i] = r
            end
        end
        layout()
    end
    d:SetScript("OnClick", function()
        if menu:IsShown() then menu:Hide(); openMenu = nil
        else if openMenu then openMenu:Hide() end; layout(); menu:Show(); openMenu = menu end
    end)
    d.SetText = function(_, t)
        d._fs:SetText(t or "")
        if kind == "font" and t and t ~= "" then
            if not d._fs:SetFont(ns.Media.Font(t), 13, "OUTLINE") then d._fs:SetFontObject("GameFontHighlight") end
        end
    end
    return d
end

-- ══ Custom input composers ════════════════════════════════════════════
-- Our own in-style colour picker + text prompt, replacing Blizzard's
-- ColorPickerFrame and StaticPopup dialogs — which pop up centre-screen, shove the
-- view around, and don't match the panel. Self-contained, reusing the toolkit above.

local function clamp01(x) return (x < 0 and 0) or (x > 1 and 1) or x end
local function hsv2rgb(h, s, v)
    local i = math.floor(h * 6); local f = h * 6 - i
    local p, q, t = v * (1 - s), v * (1 - f * s), v * (1 - (1 - f) * s)
    i = i % 6
    if i == 0 then return v, t, p elseif i == 1 then return q, v, p
    elseif i == 2 then return p, v, t elseif i == 3 then return p, q, v
    elseif i == 4 then return t, p, v else return v, p, q end
end
local function rgb2hsv(r, g, b)
    local mx, mn = math.max(r, g, b), math.min(r, g, b)
    local v, d = mx, mx - mn
    local s = (mx == 0) and 0 or (d / mx)
    local h = 0
    if d ~= 0 then
        if mx == r then h = ((g - b) / d) % 6
        elseif mx == g then h = (b - r) / d + 2
        else h = (r - g) / d + 4 end
        h = h / 6
    end
    return h, s, v
end

-- The colour composer: S/V field + hue bar + alpha + hex/RGB entry. One shared
-- instance; opens attached to the swatch that requested it and drives onChange live.
local colorComposer
local function ensureColorComposer()
    if colorComposer then return colorComposer end
    local f = CreateFrame("Frame", "Custodian_ColorComposer", UIParent)
    f:SetSize(250, 296); f:SetFrameStrata("FULLSCREEN_DIALOG"); f:SetToplevel(true)
    f:SetClampedToScreen(true); f:EnableMouse(true); f:Hide()
    bgTex(f, T.rgba(T.surface.dialog)); border(f)

    local eater = CreateFrame("Button", nil, UIParent); eater:SetFrameStrata("FULLSCREEN")
    eater:SetAllPoints(UIParent); eater:Hide(); f._eater = eater
    eater:SetScript("OnClick", function() f:Hide() end)   -- outside click keeps current
    f:SetScript("OnHide", function() f._eater:Hide() end)

    local hs = f:CreateTexture(nil, "ARTWORK"); hs:SetColorTexture(T.rgba(T.surface.titlebar))
    hs:SetPoint("TOPLEFT"); hs:SetPoint("TOPRIGHT"); hs:SetHeight(22)
    local acc = f:CreateTexture(nil, "ARTWORK"); acc:SetColorTexture(ACCENT[1], ACCENT[2], ACCENT[3], 0.5)
    acc:SetPoint("TOPLEFT", hs, "BOTTOMLEFT"); acc:SetPoint("TOPRIGHT", hs, "BOTTOMRIGHT"); acc:SetHeight(2)
    local ttl = Label(f, "Colour", "GameFontNormalSmall"); ttl:SetPoint("LEFT", hs, "LEFT", 10, 0); ttl:SetTextColor(T.rgba(T.text.title))

    -- S/V field: hue base + white(→sat) + black(→value) gradients, with a crosshair.
    local sv = CreateFrame("Frame", nil, f); sv:SetSize(160, 124); sv:SetPoint("TOPLEFT", 12, -32)
    sv:EnableMouse(true); border(sv)
    local svBase = sv:CreateTexture(nil, "BACKGROUND"); svBase:SetAllPoints()
    local svW = sv:CreateTexture(nil, "ARTWORK", nil, 0); svW:SetAllPoints(); svW:SetColorTexture(1, 1, 1, 1)
    svW:SetGradient("HORIZONTAL", CreateColor(1, 1, 1, 1), CreateColor(1, 1, 1, 0))
    local svB = sv:CreateTexture(nil, "ARTWORK", nil, 1); svB:SetAllPoints(); svB:SetColorTexture(1, 1, 1, 1)
    svB:SetGradient("VERTICAL", CreateColor(0, 0, 0, 1), CreateColor(0, 0, 0, 0))
    local crossO = sv:CreateTexture(nil, "OVERLAY", nil, 0); crossO:SetSize(9, 9); crossO:SetColorTexture(0, 0, 0, 1)
    local crossI = sv:CreateTexture(nil, "OVERLAY", nil, 1); crossI:SetSize(5, 5); crossI:SetColorTexture(1, 1, 1, 1)

    -- Hue bar: solid strips top(red)→bottom(red), guaranteed orientation. Line cursor.
    local hue = CreateFrame("Frame", nil, f); hue:SetSize(22, 124); hue:SetPoint("TOPLEFT", sv, "TOPRIGHT", 12, 0)
    hue:EnableMouse(true); border(hue)
    local NSTRIP = 32
    for k = 0, NSTRIP - 1 do
        local st = hue:CreateTexture(nil, "BACKGROUND")
        st:SetPoint("TOPLEFT", 1, -(1 + k * (122 / NSTRIP))); st:SetSize(20, 122 / NSTRIP + 1)
        local r, g, b = hsv2rgb((k + 0.5) / NSTRIP, 1, 1); st:SetColorTexture(r, g, b, 1)
    end
    local hueCurO = hue:CreateTexture(nil, "OVERLAY", nil, 0); hueCurO:SetSize(24, 4); hueCurO:SetColorTexture(0, 0, 0, 1)
    local hueCurI = hue:CreateTexture(nil, "OVERLAY", nil, 1); hueCurI:SetSize(24, 2); hueCurI:SetColorTexture(1, 1, 1, 1)

    -- Preview + hex.
    local prevBg = f:CreateTexture(nil, "BACKGROUND"); prevBg:SetColorTexture(0.3, 0.3, 0.3, 1)
    prevBg:SetPoint("TOPLEFT", sv, "BOTTOMLEFT", 0, -8); prevBg:SetSize(46, 22)
    local prev = f:CreateTexture(nil, "ARTWORK"); prev:SetAllPoints(prevBg)
    local hexLbl = Label(f, "#", "GameFontHighlightSmall"); hexLbl:SetPoint("LEFT", prevBg, "RIGHT", 8, 0); hexLbl:SetTextColor(T.rgba(T.text.label))
    local hexEB = EditBox(f, 66); hexEB:SetPoint("LEFT", hexLbl, "RIGHT", 2, 0)

    -- R / G / B (0-255).
    local rEB = EditBox(f, 38); rEB:SetPoint("TOPLEFT", prevBg, "BOTTOMLEFT", 14, -8)
    local gEB = EditBox(f, 38); gEB:SetPoint("LEFT", rEB, "RIGHT", 22, 0)
    local bEB = EditBox(f, 38); bEB:SetPoint("LEFT", gEB, "RIGHT", 22, 0)
    local rL = Label(f, "R"); rL:SetPoint("RIGHT", rEB, "LEFT", -4, 0); rL:SetTextColor(0.85, 0.5, 0.5)
    local gL = Label(f, "G"); gL:SetPoint("RIGHT", gEB, "LEFT", -4, 0); gL:SetTextColor(0.5, 0.82, 0.5)
    local bL = Label(f, "B"); bL:SetPoint("RIGHT", bEB, "LEFT", -4, 0); bL:SetTextColor(0.5, 0.6, 0.9)

    -- Alpha slider.
    local aL = Label(f, "Alpha"); aL:SetPoint("TOPLEFT", rEB, "BOTTOMLEFT", -14, -14); aL:SetTextColor(T.rgba(T.text.label))
    local aSlider = Slider(f, 0, 100, 1, 150, function(v) f._a = v / 100; f._refresh(); f._emit() end)
    aSlider:SetPoint("LEFT", aL, "RIGHT", 8, 0)

    local ok = Button(f, "OK", 66, 22); ok:SetPoint("BOTTOMLEFT", 12, 12)
    local cancel = Button(f, "Cancel", 66, 22); cancel:SetPoint("BOTTOMRIGHT", -12, 12)

    -- state + wiring
    f._refresh = function()
        local hr, hg, hb = hsv2rgb(f._h, 1, 1); svBase:SetColorTexture(hr, hg, hb, 1)
        crossO:ClearAllPoints(); crossO:SetPoint("CENTER", sv, "TOPLEFT", f._s * sv:GetWidth(), -(1 - f._v) * sv:GetHeight())
        crossI:ClearAllPoints(); crossI:SetPoint("CENTER", crossO)
        hueCurO:ClearAllPoints(); hueCurO:SetPoint("CENTER", hue, "TOP", 0, -(f._h * hue:GetHeight()))
        hueCurI:ClearAllPoints(); hueCurI:SetPoint("CENTER", hueCurO)
        local r, g, b = hsv2rgb(f._h, f._s, f._v); prev:SetColorTexture(r, g, b, f._a)
        if not f._typing then
            rEB:SetText(tostring(math.floor(r * 255 + 0.5)))
            gEB:SetText(tostring(math.floor(g * 255 + 0.5)))
            bEB:SetText(tostring(math.floor(b * 255 + 0.5)))
            hexEB:SetText(("%02X%02X%02X"):format(math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5)))
        end
        aSlider:Set(math.floor(f._a * 100 + 0.5))
    end
    f._emit = function() if f._onChange then local r, g, b = hsv2rgb(f._h, f._s, f._v); f._onChange(r, g, b, f._a) end end

    local function fromFields()
        f._h, f._s, f._v = rgb2hsv(clamp01((tonumber(rEB:GetText()) or 0) / 255),
                                   clamp01((tonumber(gEB:GetText()) or 0) / 255),
                                   clamp01((tonumber(bEB:GetText()) or 0) / 255))
        f._refresh(); f._emit()
    end
    for _, eb in ipairs({ rEB, gEB, bEB }) do eb:SetScript("OnEditFocusLost", fromFields) end
    hexEB:SetScript("OnEditFocusLost", function()
        local hx = hexEB:GetText():gsub("#", ""):gsub("%s", "")
        if #hx >= 6 then
            local r, g, b = tonumber(hx:sub(1, 2), 16), tonumber(hx:sub(3, 4), 16), tonumber(hx:sub(5, 6), 16)
            if r and g and b then f._h, f._s, f._v = rgb2hsv(r / 255, g / 255, b / 255); f._refresh(); f._emit() end
        end
    end)

    sv:SetScript("OnMouseDown", function() f._drag = "sv" end)
    hue:SetScript("OnMouseDown", function() f._drag = "hue" end)
    f:SetScript("OnUpdate", function()
        if not f._drag then return end
        if not IsMouseButtonDown("LeftButton") then f._drag = nil; return end
        local sc = f:GetEffectiveScale(); local cx, cy = GetCursorPosition(); cx, cy = cx / sc, cy / sc
        if f._drag == "sv" then
            f._s = clamp01((cx - sv:GetLeft()) / sv:GetWidth())
            f._v = clamp01((cy - sv:GetBottom()) / sv:GetHeight())   -- top = bright (value 1), matching the gradient + crosshair
        else
            f._h = clamp01((hue:GetTop() - cy) / hue:GetHeight()); if f._h >= 1 then f._h = 0.9999 end
        end
        f._refresh(); f._emit()
    end)

    ok:SetScript("OnClick", function() f:Hide() end)
    cancel:SetScript("OnClick", function()
        local o = f._orig; if o and f._onChange then f._onChange(o.r, o.g, o.b, o.a) end; f:Hide()
    end)
    tinsert(UISpecialFrames, "Custodian_ColorComposer")   -- Esc closes (keeps current)
    colorComposer = f
    return f
end

local function openColorComposer(anchor, r, g, b, a, onChange)
    local f = ensureColorComposer()
    f._onChange = onChange
    a = a or 1
    f._orig = { r = r, g = g, b = b, a = a }
    f._h, f._s, f._v = rgb2hsv(r, g, b); f._a = a
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", anchor or UIParent, anchor and "TOPRIGHT" or "CENTER", anchor and 8 or 0, 0)
    f._refresh()
    f._eater:Show(); f:Show(); f:Raise()
end

-- The text prompt: a styled name / confirm box replacing StaticPopup. `confirm`
-- omits the input (yes/no only). Centres over the panel when it's open.
local promptFrame
local function ensurePrompt()
    if promptFrame then return promptFrame end
    local f = CreateFrame("Frame", "Custodian_Prompt", UIParent)
    f:SetSize(320, 130); f:SetFrameStrata("FULLSCREEN_DIALOG"); f:SetToplevel(true); f:EnableMouse(true); f:Hide()
    bgTex(f, T.rgba(T.surface.dialog)); border(f)
    local eater = CreateFrame("Button", nil, UIParent); eater:SetFrameStrata("FULLSCREEN"); eater:SetAllPoints(UIParent); eater:Hide(); f._eater = eater
    eater:SetScript("OnClick", function() f:Hide() end)
    f:SetScript("OnHide", function() f._eater:Hide() end)
    local hs = f:CreateTexture(nil, "ARTWORK"); hs:SetColorTexture(T.rgba(T.surface.titlebar))
    hs:SetPoint("TOPLEFT"); hs:SetPoint("TOPRIGHT"); hs:SetHeight(24)
    local acc = f:CreateTexture(nil, "ARTWORK"); acc:SetColorTexture(ACCENT[1], ACCENT[2], ACCENT[3], 0.5)
    acc:SetPoint("TOPLEFT", hs, "BOTTOMLEFT"); acc:SetPoint("TOPRIGHT", hs, "BOTTOMRIGHT"); acc:SetHeight(2)
    f._title = Label(f, "", "GameFontNormal"); f._title:SetPoint("LEFT", hs, "LEFT", 12, 0)
    f._body = Label(f, "", "GameFontHighlightSmall"); f._body:SetTextColor(T.rgba(T.text.label))
    f._body:SetPoint("TOPLEFT", 16, -36); f._body:SetPoint("TOPRIGHT", -16, -36); f._body:SetJustifyH("LEFT")
    f._eb = EditBox(f, 288)
    local ok = Button(f, "OK", 74, 22); ok:SetPoint("BOTTOMRIGHT", -14, 12); f._ok = ok
    local cancel = Button(f, "Cancel", 74, 22); cancel:SetPoint("RIGHT", ok, "LEFT", -8, 0)
    local function accept() if f._onAccept then f._onAccept(f._confirm and true or f._eb:GetText()) end; f:Hide() end
    ok:SetScript("OnClick", accept)
    cancel:SetScript("OnClick", function() f:Hide() end)
    f._eb:SetScript("OnEnterPressed", accept)
    f._eb:SetScript("OnEscapePressed", function() f:Hide() end)
    tinsert(UISpecialFrames, "Custodian_Prompt")
    promptFrame = f
    return f
end

local function openPrompt(opts)
    local f = ensurePrompt()
    f._onAccept = opts.onAccept
    f._confirm = opts.confirm and true or false
    f._title:SetText(opts.title or "")
    f._ok._fs:SetText(opts.accept or "OK")
    local top = 34
    if opts.body and opts.body ~= "" then
        f._body:SetText(opts.body); f._body:Show(); top = 60
    else
        f._body:Hide()
    end
    if f._confirm then
        f._eb:Hide()
        f:SetHeight(top + 44)
    else
        f._eb:ClearAllPoints(); f._eb:SetPoint("TOPLEFT", 16, -top)
        f._eb:Show(); f._eb:SetText(opts.initial or ""); f._eb:HighlightText(); f._eb:SetFocus()
        f:SetHeight(top + 30 + 40)
    end
    local host = _G.Custodian_Options
    f:ClearAllPoints(); f:SetPoint("CENTER", (host and host:IsShown() and host) or UIParent, "CENTER", 0, 30)
    f._eater:Show(); f:Show(); f:Raise()
end

local function ColorSwatch(parent, getColor, onChange)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(22, 22); border(b)
    local sw = b:CreateTexture(nil, "ARTWORK"); sw:SetPoint("TOPLEFT", 1, -1); sw:SetPoint("BOTTOMRIGHT", -1, 1); b._sw = sw
    b.Refresh = function() local c = getColor(); sw:SetColorTexture(c.r, c.g, c.b, c.a or 1) end
    b:SetScript("OnClick", function()
        local c = getColor()
        openColorComposer(b, c.r, c.g, c.b, c.a or 1, function(r, g, bl, a)
            onChange(r, g, bl, a); b.Refresh()
        end)
    end)
    return b
end

-- Attach a hover tooltip (hooks, so it composes with a control's own hover anim).
local function tip(frame, title, body)
    if not frame then return frame end
    frame:HookScript("OnEnter", function()
        GameTooltip:SetOwner(frame, "ANCHOR_RIGHT")
        GameTooltip:AddLine(title, 1, 1, 1)
        if body then GameTooltip:AddLine(body, 0.72, 0.78, 0.86, true) end
        GameTooltip:Show()
    end)
    frame:HookScript("OnLeave", function() GameTooltip:Hide() end)
    return frame
end

-- Show the GAME spell tooltip on hover wherever a spell is displayed, so you can
-- tell which spell is which. getID() returns the spell id (or nil = no tooltip).
-- `others` (optional) returns a list of the other bundled ids to list beneath.
local function spellTip(frame, getID, others)
    frame:HookScript("OnEnter", function()
        local id = getID and getID()
        if not (id and GameTooltip.SetSpellByID) then return end
        GameTooltip:SetOwner(frame, "ANCHOR_RIGHT")
        GameTooltip:SetSpellByID(id)
        local list = others and others()
        if list and #list > 1 then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Bundled (uses whichever you have):", 0.62, 0.78, 1)
            for _, sid in ipairs(list) do
                local nm = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(sid)
                GameTooltip:AddLine((sid == id and "|cff40ff40" or "|cffb0b0b0") .. (nm or ("id " .. sid)) .. "|r")
            end
        end
        GameTooltip:Show()
    end)
    frame:HookScript("OnLeave", function() GameTooltip:Hide() end)
    return frame
end


-- Close whatever dropdown menu is currently open (the panel calls this on hide).
function UI.CloseMenus() if openMenu then openMenu:Hide(); openMenu = nil end end

-- ── Exposed on ns.UI ──────────────────────────────────────────────────
UI.ACCENT = ACCENT
UI.border, UI.bgTex, UI.tweenAlpha = border, bgTex, tweenAlpha
UI.Label, UI.Button, UI.Check, UI.Slider, UI.EditBox, UI.Dropdown = Label, Button, Check, Slider, EditBox, Dropdown
UI.ItemField = ItemField
UI.ColorSwatch, UI.tip, UI.spellTip = ColorSwatch, tip, spellTip
UI.openPrompt = openPrompt
