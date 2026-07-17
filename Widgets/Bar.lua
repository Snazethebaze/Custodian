-- Widgets/Bar.lua : the "bar" display — a smooth horizontal fill + text.
-- Renders the NORMALIZED snapshot, so it works for any tracker (power,
-- aura stacks, cooldown remaining, …) with no special-casing.

local ADDON, ns = ...
local Media     = ns.Media
local Animation = ns.Animation

local Bar = {}
ns.RegisterDisplay("bar", Bar)

-- ── "Glow when full" (native LibCustomGlow around the whole bar) ───────
-- A readable value at/over max lights a glow — DH's Void Metamorphosis pool at cap, MSW at 10,
-- runes full… Mirrors Icon's native-glow handling, incl. the double-release guards: LibCustomGlow
-- pool objects error ("doesn't belong to this pool") if Stop runs twice or for the wrong style,
-- so we track _fgOn / _fgStyle and only ever stop the one that's actually running.
local LCG = LibStub and LibStub("LibCustomGlow-1.0", true)
local FULL_GLOW = LCG and {
    pixel    = { start = LCG.PixelGlow_Start,    stop = LCG.PixelGlow_Stop },
    autocast = { start = LCG.AutoCastGlow_Start, stop = LCG.AutoCastGlow_Stop },
    proc     = { start = LCG.ProcGlow_Start,     stop = LCG.ProcGlow_Stop },
    blizzard = { start = LCG.ButtonGlow_Start,   stop = LCG.ButtonGlow_Stop },
}

local function stopFullGlow(w)
    if LCG and w._fgOn then
        local native = FULL_GLOW[w._fgStyle or ""]
        if native and native.stop then pcall(native.stop, w.frame) end
    end
    w._fgOn = false
    w._fgStyle = nil
end

-- Show/hide the full-bar glow. Style comes from cfg.glowStyle when it's a native one, else pixel
-- (the icon-only texture styles — outline/fill/border — don't apply to a bar frame).
function Bar.SetFullGlow(w, on)
    if not LCG then return end
    local style = w.cfg.glowStyle
    if not (style and FULL_GLOW[style]) then style = "pixel" end
    if on then
        if not w._fgOn or w._fgStyle ~= style then
            stopFullGlow(w)
            local c = w.cfg.fullGlowColor or { r = 1, g = 0.85, b = 0.2, a = 1 }
            local col = { c.r, c.g, c.b, c.a or 1 }
            local native = FULL_GLOW[style]
            if style == "proc" then pcall(native.start, w.frame, { color = col })
            else pcall(native.start, w.frame, col) end
            w._fgOn = true
            w._fgStyle = style
        end
    else
        stopFullGlow(w)
    end
end

local function abbr(n)
    if AbbreviateNumbers and n and n >= 1000 then return AbbreviateNumbers(n) end
    return tostring(n or 0)
end

-- Remaining-time text for a duration (timer) bar — shared with icons so a buff reads the same
-- on both ("2m" / "45" / "2.4"). See ns.FormatRemaining (Core/Custodian.lua).
local fmtDur = ns.FormatRemaining

-- Bar text sits 3px off the corner (see ns.TextAnchor in Widgets/Widget.lua).
local function textAnchor(a, default) return ns.TextAnchor(a, default, 3) end

function Bar.Create(w)
    local f = w.frame

    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(f)
    bg:SetColorTexture(0, 0, 0, 0.55)
    w.bg = bg

    local sb = CreateFrame("StatusBar", nil, f)
    sb:SetPoint("TOPLEFT", f, "TOPLEFT", 1, -1)
    sb:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -1, 1)
    sb:SetMinMaxValues(0, 1)
    sb:SetValue(0)
    w.sb = sb

    -- Duration (timer) bar: while a readable expiry is set (an aura shown as a bar), glide the
    -- fill down each frame so it drains smoothly. Bar.Update seeds w._durExp / w._durTotal and
    -- the 0..dur range; here we only re-set the value (min/max already match).
    f:SetScript("OnUpdate", function(self, dt)
        local exp, dur = w._durExp, w._durTotal
        if not (exp and dur and dur > 0) then return end
        self._durAcc = (self._durAcc or 0) + dt
        if self._durAcc < 0.03 then return end
        self._durAcc = 0
        local rem = exp - GetTime()
        if rem <= 0 then
            w.sb:SetValue(0); w._durExp = nil
            if w.cfg.showText ~= false then w.text:SetText("") end
            return
        end
        w.sb:SetValue(rem)
        if w.cfg.showText ~= false then w.text:SetText(fmtDur(rem)) end
    end)

    -- phase-2 overlay fill for 5+5 split mode (above phase 1, below markers)
    local sb2 = CreateFrame("StatusBar", nil, f)
    sb2:SetPoint("TOPLEFT", f, "TOPLEFT", 1, -1)
    sb2:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -1, 1)
    sb2:SetFrameLevel(sb:GetFrameLevel() + 1)
    sb2:SetMinMaxValues(0, 1)
    sb2:SetValue(0)
    sb2:Hide()
    local sb2bg = sb2:CreateTexture(nil, "BACKGROUND")
    sb2bg:SetAllPoints(sb2)
    sb2bg:SetColorTexture(0, 0, 0, 0)
    w.sb2, w.sb2bg = sb2, sb2bg

    -- markers: static / dynamic vertical reference lines, above the fill
    local mov = CreateFrame("Frame", nil, sb)
    mov:SetAllPoints(sb)
    mov:SetFrameLevel(sb:GetFrameLevel() + 2)
    w.markerOv = mov
    w.markers = {}
    for i = 1, 8 do
        local t = mov:CreateTexture(nil, "OVERLAY")
        t:SetColorTexture(1, 1, 1, 0.9)
        t:Hide()
        w.markers[i] = t
    end

    -- segment dividers: the old "pips" look, folded into the bar as an option.
    -- Static (position from a fraction, never a value) so they're secret-safe.
    w.segDividers = {}
    for i = 1, 30 do
        local t = mov:CreateTexture(nil, "OVERLAY")
        t:SetColorTexture(0, 0, 0, 0.9)
        t:Hide()
        w.segDividers[i] = t
    end

    -- Segment BOXES: the alternate render for a segmented bar WITH a gap — N independent
    -- StatusBars with truly see-through gaps between them (vs divider lines over one fill).
    -- Each spans [i-1, i] and is fed the (secret-safe) value, so the engine fills exactly the
    -- covered boxes without us ever reading the number. Mouse is off, so the gaps click through.
    w.segBoxes = {}
    for i = 1, 30 do
        local box = CreateFrame("StatusBar", nil, f)
        box:SetMinMaxValues(i - 1, i)
        box:SetValue(0)
        box:EnableMouse(false)
        local bbg = box:CreateTexture(nil, "BACKGROUND")
        bbg:SetAllPoints(box)
        bbg:SetColorTexture(0, 0, 0, 0.55)   -- the box's own "empty" backing; only the GAPS are clear
        box._bg = bbg
        box._edges = ns.MakeEdges(box, "OVERLAY")   -- a per-box frame (vs one border round the whole bar)
        box:Hide()
        w.segBoxes[i] = box
    end

    w.edges = ns.MakeEdges(f, "BORDER", 0, 0, 0, 1)

    -- Leading-edge spark: anchored to the fill TEXTURE's right edge, so it tracks
    -- the fill without our code ever reading the (secret) value — the engine sizes
    -- the fill, the spark rides it. This is the only motion we can give a secret
    -- power bar (Maelstrom / Mana), whose fill can't be Lua-tweened; it's also a
    -- nice touch riding a smoothly animating readable bar. On ARTWORK so it sits
    -- above the fill but below the markers / text (both OVERLAY).
    local spark = mov:CreateTexture(nil, "ARTWORK")
    spark:SetTexture("Interface\\CastingBar\\UI-CastingBar-Spark")
    spark:SetBlendMode("ADD")
    spark:Hide()
    w.spark = spark

    -- text on the marker overlay so it stays above the phase-2 fill
    local text = mov:CreateFontString(nil, "OVERLAY")
    text:SetPoint("CENTER", mov, "CENTER", 0, 0)
    w.text = text

    -- When this bar is hidden (spec change, etc.) drop any button glows it owns,
    -- so an affordable spender doesn't stay lit on a bar you can no longer see.
    f:HookScript("OnHide", function() Bar.StopGlows(w) end)
end

-- How many boxes to draw across the bar width. Shared with icon charge-pips via
-- ns.SegmentCount (5+5 split phase / tracker max / discrete-power live ceiling / numeric
-- cfg.segments / default 10) — see Core\Custodian.lua.
local function segCount(w) return ns.SegmentCount(w.cfg, 10) end

local MAX_SEG = 30
-- Divider lines that split the fill into N evenly spaced segments. Pixel-snapped
-- so every line is crisp and even. Secret-safe: positions come from a fraction
-- of the width, never from a value.
function Bar.Segments(w)
    for i = 1, MAX_SEG do w.segDividers[i]:Hide() end
    local segs = segCount(w)
    if not segs or segs < 2 then return end
    if segs > MAX_SEG then segs = MAX_SEG end

    local scale = w.frame:GetEffectiveScale()
    if not scale or scale <= 0 then scale = 1 end
    local ins = w._borderInset or 1
    local width = (w.cfg.width or 240) - ins * 2   -- match the status bar's ACTUAL width

    -- gap 0 = the classic thin divider; gap > 0 (only reached with 5+5 split — box mode handles the
    -- rest) = a wider opaque block. Work in PHYSICAL pixels and snap each divider's left edge onto
    -- the pixel grid, opaque — a half-pixel, 0.9-alpha line antialiases across two pixels and lets
    -- the fill bleed a hair past the boundary. Secret-safe: positions come from a fraction, never a value.
    local gap = w.cfg.segmentGap or 0
    for i = 1, segs - 1 do
        local t = w.segDividers[i]
        local edgePx = (i / segs) * width * scale   -- the segment boundary, in physical px
        local wPx, leftPx
        if gap > 0 then
            wPx = math.max(1, math.floor(gap * scale + 0.5))
            leftPx = math.floor(edgePx - wPx / 2 + 0.5)
        else
            wPx = 1
            leftPx = math.floor(edgePx)             -- the pixel the boundary falls in
        end
        t:SetColorTexture(0, 0, 0, 1)               -- opaque so the fill can't show through
        t:SetWidth(wPx / scale)
        t:ClearAllPoints()
        t:SetPoint("TOP", w.sb, "TOPLEFT", leftPx / scale, 0)
        t:SetPoint("BOTTOM", w.sb, "BOTTOMLEFT", leftPx / scale, 0)
        t:Show()
    end
end

-- The bar's base fill colour. Normally cfg.color, but a SPEC-DYNAMIC resource (DK runes) with
-- cfg.autoPowerColor set follows the current spec instead (Blood red / Frost blue / Unholy green),
-- recolouring on a spec swap. A manual colour pick clears autoPowerColor (see the editor), so the
-- user's choice always wins. Used by both the boxed and continuous paths.
local function baseColor(w)
    local cfg = w.cfg
    if cfg.autoPowerColor then
        local tr = ns.TrackerOf(cfg)
        if tr and tr.type == "power" then
            -- PRIMARY: colour to the CURRENT form's power (Energy yellow in Cat, Rage red in Bear).
            if tr.power == "PRIMARY" and ns.CurrentPowerColor then
                local r, g, b, a = ns.CurrentPowerColor(cfg.unit or tr.unit or "player")
                if r then return { r = r, g = g, b = b, a = a or 1 } end
            elseif ns.PowerColorForSpec then   -- spec-coloured (DK runes)
                local r, g, b, a = ns.PowerColorForSpec(tr.power, ns.specID)
                if r then return { r = r, g = g, b = b, a = a or 1 } end
            end
        end
    end
    return cfg.color or { r = 0.2, g = 0.6, b = 1, a = 1 }
end

-- A tracker can drive a live fill colour for one update via snap.fillColor — a STATE change the
-- fill percent can't express (e.g. DH's bar flips colour while Void Metamorphosis is active).
-- Applied last so it wins for that frame. When the state ENDS we restore the base colour once
-- (curve/threshold bars re-colour themselves earlier in Update, so only plain bars rely on this).
local function applyStateColor(w, snap)
    local fc = snap and snap.fillColor
    if fc then
        w.sb:SetStatusBarColor(fc.r, fc.g, fc.b, fc.a or 1)
        w._stateColored = true
    elseif w._stateColored then
        local c = baseColor(w)
        w.sb:SetStatusBarColor(c.r, c.g, c.b, c.a or 1)
        w._stateColored = nil
    end
end

-- Lay out a segmented bar as N independent boxes with a see-through gap between them (the
-- gaps show the world through, and click through, rather than a dark strip). Box i spans
-- [i-1, i]; Bar.Update feeds the (secret-safe) value to every box so the engine fills the
-- covered ones. Called from ApplyStyle and again when the live ceiling changes.
function Bar.LayoutBoxes(w)
    local cfg = w.cfg
    local n = segCount(w) or 0
    if n < 1 then n = 1 end
    if n > MAX_SEG then n = MAX_SEG end
    w._boxCount = n

    local gap = cfg.segmentGap or ns.SEG_GAP_DEFAULT   -- unset = a small transparent gap (pip-like); 0 = touching
    local ins = w._borderInset or 1
    local innerW = (cfg.width or 240) - ins * 2
    local boxW = ns.CellWidth(innerW, n, gap)
    local tex = Media.Bar(cfg.texture)
    local col = baseColor(w)
    local scale = w.frame:GetEffectiveScale(); if not scale or scale <= 0 then scale = 1 end
    -- Snap a UI coordinate to the physical pixel grid. Every box edge (left/right/top/bottom) is
    -- snapped, so each box is a WHOLE number of pixels — otherwise a fractional box width lands the
    -- right edge on a half-pixel and its border renders thicker than the (snapped) left edge.
    local function snap(u) return math.floor(u * scale + 0.5) / scale end
    local topY = snap(ins)
    local h = snap((cfg.height or 26) - ins) - topY

    -- Below the text host (markerOv, at sb+2) so the count still reads on top, above the bg.
    local boxLevel = w.sb:GetFrameLevel() + 1
    for i = 1, n do
        local box = w.segBoxes[i]
        local leftU = ins + (i - 1) * (boxW + gap)
        local left, right = snap(leftU), snap(leftU + boxW)
        box:ClearAllPoints()
        box:SetPoint("TOPLEFT", w.frame, "TOPLEFT", left, -topY)
        box:SetSize(right - left, h)
        box:SetFrameLevel(boxLevel)
        box:SetStatusBarTexture(tex)
        box:SetStatusBarColor(col.r, col.g, col.b, col.a or 1)
        box._bg:SetVertexColor(1, 1, 1, 1); box._bg:SetColorTexture(0, 0, 0, 0.55)   -- reset empty backing (RenderSplitBoxes may have set a texture+tint)
        box:SetMinMaxValues(i - 1, i)
        ns.ApplyBorder(box._edges, box, cfg)   -- frame THIS box (thickness/colour from cfg; 0 = none)
        box:Show()
    end
    for i = n + 1, MAX_SEG do w.segBoxes[i]:Hide() end
end

-- Fill-glide duration for READABLE bars. `cfg.smooth == false` disables the
-- tween (Animation.To with 0 duration applies instantly), so it reads as a snap.
-- Secret bars never reach here — their fill can't be Lua-tweened at all.
local SMOOTH_TIME = 0.25
local function smoothTime(w)
    return (w.cfg.smooth == false) and 0 or SMOOTH_TIME
end

-- Park the spark on the leading fill edge. Secret-safe: it anchors to the fill
-- TEXTURE (engine-positioned from SetValue), never to a value we read. In 5+5
-- split mode the leading edge is the phase-2 bar once it's showing, so follow
-- whichever fill is on top.
local function updateSpark(w)
    local spark = w.spark
    if not (spark and w.cfg.spark) then if spark then spark:Hide() end return end
    local lead = (w.sb2 and w.sb2:IsShown()) and w.sb2 or w.sb
    local ft = lead:GetStatusBarTexture()
    if not ft then spark:Hide(); return end
    local h = w.cfg.height or 26
    spark:SetSize(math.max(8, h * 0.5), h * 1.6)
    spark:ClearAllPoints()
    spark:SetPoint("CENTER", ft, "RIGHT", 0, 0)
    spark:Show()
end

-- Spark for BOX mode: ride the right edge of the box currently filling (box ceil(value)).
-- Needs a READABLE value to know which box leads, so it's hidden for secret / empty bars.
local function updateBoxSpark(w, value)
    local spark = w.spark
    if not spark then return end
    if not w.cfg.spark or ns.IsSecret(value) or (value or 0) <= 0 then spark:Hide(); return end
    local lead = math.min(w._boxCount or 0, math.ceil(value))
    local box = (lead >= 1) and w.segBoxes[lead]
    local ft = box and box:GetStatusBarTexture()
    if not ft then spark:Hide(); return end
    local h = w.cfg.height or 26
    spark:SetSize(math.max(8, h * 0.5), h * 1.6)
    spark:ClearAllPoints()
    spark:SetPoint("CENTER", ft, "RIGHT", 0, 0)
    spark:Show()
end

-- 5+5 split rendered as BOXES (readable values only — the split compares against `at`). There are
-- `at` boxes. Phase 1 (value ≤ at) fills them left-to-right in the phase-1 colour over an empty
-- backing. Phase 2 (value > at) paints every box's backing the phase-1 colour (those stacks are
-- "done") and fills the phase-2 colour on top for the (value − at) stacks past the divider — so a
-- single box can show both tones, and the leading box glides. Called each animation frame.
function Bar.RenderSplitBoxes(w, value, max)
    local cfg = w.cfg
    local at = cfg.split.at or 5
    local n = w._boxCount or 0
    local c1 = (ns.ColorCurve and ns.ColorCurve.ColorAt(cfg, value, max)) or cfg.color or { r = 1, g = 0.55, b = 0.05, a = 1 }
    local c2 = cfg.split.color or { r = 0.60, g = 0.20, b = 1, a = 1 }
    local phase2 = value > at
    local fill = phase2 and (value - at) or value   -- how far the ACTIVE phase has filled
    local tex = phase2 and Media.Bar(cfg.texture) or nil
    for i = 1, n do
        local box = w.segBoxes[i]
        if box then
            box:SetValue(fill)
            if phase2 then
                box:SetStatusBarColor(c2.r, c2.g, c2.b, c2.a or 1)
                -- phase-1-full backing: the bar's chosen TEXTURE tinted the phase-1 colour (not a flat
                -- block), so a box behind the phase-2 fill still reads as the same bar texture.
                box._bg:SetTexture(tex); box._bg:SetVertexColor(c1.r, c1.g, c1.b, c1.a or 1)
            else
                box:SetStatusBarColor(c1.r, c1.g, c1.b, c1.a or 1)
                box._bg:SetVertexColor(1, 1, 1, 1); box._bg:SetColorTexture(0, 0, 0, 0.55)   -- empty backing
            end
        end
    end
end

function Bar.ApplyStyle(w)
    local cfg = w.cfg
    local tex = Media.Bar(cfg.texture)
    w.sb:SetStatusBarTexture(tex)
    w.sb2:SetStatusBarTexture(tex)
    local c = baseColor(w)
    w.sb:SetStatusBarColor(c.r, c.g, c.b, c.a or 1)
    w._curve = ns.ColorCurve and ns.ColorCurve.Build(cfg.colorCurve) or nil   -- colour-by-fill, or nil
    ns.SetFontReflow(w.text, Media.Font(cfg.font), cfg.fontSize or 13, "OUTLINE")
    local ap, bx, by, jh = textAnchor(cfg.textAnchor, "CENTER")
    w.text:ClearAllPoints()
    w.text:SetPoint(ap, w.markerOv, ap, bx + (cfg.textOffsetX or 0), by + (cfg.textOffsetY or 0))
    w.text:SetJustifyH(jh)
    w.text:SetShown(cfg.showText ~= false)
    -- Configurable border (thickness + colour, 0 = none). Inset the fill by the border
    -- thickness so a thicker frame doesn't get painted over by the status bar.
    local bth = ns.ApplyBorder(w.edges, w.frame, cfg)
    local ins = math.max(bth, 0)
    w._borderInset = ins
    w.sb:ClearAllPoints();  w.sb:SetPoint("TOPLEFT", w.frame, "TOPLEFT", ins, -ins);  w.sb:SetPoint("BOTTOMRIGHT", w.frame, "BOTTOMRIGHT", -ins, ins)
    w.sb2:ClearAllPoints(); w.sb2:SetPoint("TOPLEFT", w.frame, "TOPLEFT", ins, -ins); w.sb2:SetPoint("BOTTOMRIGHT", w.frame, "BOTTOMRIGHT", -ins, ins)

    -- A segmented bar renders as independent boxes — each its own bordered cell with see-through
    -- gaps between (like icon charge-pips), never a solid bar with dark backing + divider lines.
    -- The 5+5 split renders as boxes too: `at` boxes, with the phase-2 colour filling over a
    -- phase-1-coloured box backing (see Bar.RenderSplitBoxes).
    w._boxMode = (cfg.segments) and true or false
    w._segMax = nil   -- force a rebuild against the live ceiling on the next Update
    if w._boxMode then
        -- Keep sb SHOWN but invisible (fill alpha 0) so the text host — a child of sb — stays
        -- visible; the boxes draw the actual segments. The whole-bar border is dropped in favour
        -- of a frame around EACH box (see LayoutBoxes), and the boxes span the full width.
        w.sb:Show(); w.sb:SetStatusBarColor(0, 0, 0, 0); w.sb:SetValue(0)
        w.sb2:Hide(); w.bg:Hide()
        if w.spark then w.spark:Hide() end   -- Update re-shows it on the leading box
        for _, k in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do w.edges[k]:Hide() end
        w._borderInset = 0
        for i = 1, MAX_SEG do w.segDividers[i]:Hide() end
        Bar.LayoutBoxes(w)
    else
        w.sb:Show(); w.bg:Show()
        for i = 1, MAX_SEG do w.segBoxes[i]:Hide() end
        Bar.Segments(w)
        updateSpark(w)   -- re-anchor to the (possibly new) fill texture + toggle on/off
    end
end

local function formatText(cfg, snap)
    local mode = cfg.textFormat or "valuemax"
    local v, m = snap.value or 0, snap.max or 0
    if mode == "value" then
        return abbr(v)
    elseif mode == "percent" then
        return (m > 0) and (math.floor(v / m * 100 + 0.5) .. "%") or "0%"
    elseif mode == "valuepercent" then
        local pct = (m > 0) and math.floor(v / m * 100 + 0.5) or 0
        return abbr(v) .. " (" .. pct .. "%)"
    end
    return abbr(v) .. " / " .. abbr(m)
end

-- Markers are secret-safe: position comes from a fraction of the bar —
--   percent : straight fraction (needs nothing readable; great for Mana)
--   value   : a literal value over the (readable) max
--   spell   : the spell's live power cost over max (auto-shifts with talents)
-- never from the current secret value.
local MAX_MARKERS = 8
function Bar.Markers(w, max)
    for i = 1, MAX_MARKERS do w.markers[i]:Hide() end
    local defs = w.cfg.markers
    if not defs then return end

    -- Power type of this bar's tracker, so a spell-cost marker picks the
    -- matching cost entry rather than a spurious 0-cost first entry.
    local tcfg = ns.TrackerOf(w.cfg)
    -- Mana is a drained pool, not a gated spend — value lines are meaningless there
    -- (the panel hides their editor too), so never draw them / hold glows on a mana
    -- bar. Markers were already hidden above; drop any glows this bar owned.
    if tcfg and tcfg.power == "MANA" then Bar.StopGlows(w); return end
    local powerType = tcfg and tcfg.power and ns.PowerTypes and ns.PowerTypes[tcfg.power]

    local innerW = (w.cfg.width or 240) - 2
    local scale = w.frame:GetEffectiveScale()
    if not scale or scale <= 0 then scale = 1 end
    -- IsSecret first so we never compare a secret max.
    local maxReadable = max and not ns.IsSecret(max) and max > 0

    local wantGlow   -- spellID -> marker, for alert spenders currently affordable
    for i, m in ipairs(defs) do
        if i > MAX_MARKERS then break end
        -- Spec-gated markers: a shared resource bar (one bar on every DK spec) can carry
        -- per-spec lines/glows — Blood's Death Strike, Unholy's something else. m.specs is a
        -- SET of specIDs it applies to; nil/empty = every spec. Off-spec markers draw nothing
        -- and hold no glow (the wantGlow diff below stops any they owned last pass).
        if not (m.specs and next(m.specs)) or (ns.specID and m.specs[ns.specID]) then
        local sid = (m.mode == "spell") and ns.MarkerSpell(m) or nil   -- resolve a bundle to the id you have
        local frac
        if m.mode == "percent" then
            local pct = m.value or 0
            if pct > 0 and pct < 100 then frac = pct / 100 end
        elseif maxReadable then
            local val = (m.mode == "spell") and ns.SpellCost(sid, powerType) or m.value
            if val and val > 0 and val < max then frac = val / max end
        end

        -- Affordability alert: light up the REAL action-bar button when the
        -- spender becomes castable (secret-safe — IsSpellUsable's booleans are
        -- readable even while the power value is secret). Gated on SpellKnown so
        -- an untalented choice-node spell never glows. Independent of the line.
        if m.mode == "spell" and m.alert and sid and ns.SpellKnown(sid) then
            local _, insuff = ns.SpellUsable(sid)
            if insuff == false then
                wantGlow = wantGlow or {}
                wantGlow[sid] = m
            end
        end

        if frac and m.line ~= false then   -- m.line == false = glow-only (draw no line)
            local t = w.markers[i]
            local c = m.color or { r = 1, g = 1, b = 1, a = 0.9 }
            local x  = math.floor(frac * innerW * scale + 0.5) / scale
            local ww = (m.width or 2) / scale
            local cr, cg, cb, ca = c.r, c.g, c.b, c.a or 0.9
            -- The line only MOVES when the cost/max/width/scale change — not on the ~10-20 Hz power
            -- ticks that call this. `x` is derived from all of those, so skipping the re-layout when
            -- (x, width, colour) are unchanged is a free auto-invalidating cache (Hide doesn't clear
            -- points, so the anchor survives a hidden pass). Show() stays — it's ~free.
            if t._mx ~= x or t._mw ~= ww or t._mr ~= cr or t._mg ~= cg or t._mb ~= cb or t._ma ~= ca then
                t._mx, t._mw, t._mr, t._mg, t._mb, t._ma = x, ww, cr, cg, cb, ca
                t:SetColorTexture(cr, cg, cb, ca)
                t:ClearAllPoints()
                t:SetPoint("TOPLEFT", w.sb, "TOPLEFT", x, 0)
                t:SetPoint("BOTTOMLEFT", w.sb, "BOTTOMLEFT", x, 0)
                t:SetWidth(ww)
            end
            t:Show()
        end
        end   -- spec gate
    end

    -- Diff desired glows against last pass: start newly affordable spenders (with
    -- their transition sound), stop ones no longer affordable / alerting.
    w._glowSet = w._glowSet or {}
    if wantGlow then
        for id, m in pairs(wantGlow) do
            if not w._glowSet[id] then
                ns.Glow.Start(id)
                if m.sound then ns.PlaySound(m.sound) end
            end
        end
    end
    for id in pairs(w._glowSet) do
        if not (wantGlow and wantGlow[id]) then ns.Glow.Stop(id) end
    end
    w._glowSet = wantGlow or {}
end

-- Release any button glows this bar owns (spec change hides it, deletion, etc.).
function Bar.StopGlows(w)
    stopFullGlow(w)
    if not w._glowSet then return end
    for id in pairs(w._glowSet) do ns.Glow.Stop(id) end
    w._glowSet = {}
end

function Bar.Destroy(w)
    Bar.StopGlows(w)
end

-- Re-evaluate affordability glows when usability changes without a power tick
-- (silence, a cost change, leaving combat…). Power crossings already re-run
-- Bar.Markers via Bar.Update; this just adds SPELL_UPDATE_USABLE as a trigger.
local usableWatcher = CreateFrame("Frame")
usableWatcher:RegisterEvent("SPELL_UPDATE_USABLE")
usableWatcher:SetScript("OnEvent", function()
    for _, w in pairs(ns.widgets) do
        if w.disp == Bar and w.frame and w.frame:IsShown() and w.cfg.markers then
            Bar.Markers(w, w._lastMax)
        end
    end
end)

-- A PRIMARY (form-following) bar must recolour when the active power changes — Cat→Bear flips
-- Energy→Rage. UNIT_DISPLAYPOWER fires on that swap; the value re-reads via the tracker, but the
-- base colour is only set in ApplyStyle, so re-apply it here for any autoPowerColor bar.
local dispPowerWatcher = CreateFrame("Frame")
dispPowerWatcher:RegisterEvent("UNIT_DISPLAYPOWER")
dispPowerWatcher:SetScript("OnEvent", function(_, _, unit)
    if unit ~= "player" then return end
    for _, w in pairs(ns.widgets) do
        if w.disp == Bar and w.cfg.autoPowerColor and not w.cfg.colorCurve then
            local c = baseColor(w)
            w.sb:SetStatusBarColor(c.r, c.g, c.b, c.a or 1)
            if w._boxCount then
                for i = 1, w._boxCount do
                    local box = w.segBoxes[i]; if box then box:SetStatusBarColor(c.r, c.g, c.b, c.a or 1) end
                end
            end
        end
    end
end)

-- Colour the fill from a ColorCurve evaluated on the (secret) power percent.
-- Returns true if it set a colour; false leaves the base colour in place.
local function applyFillColor(w)
    if not w._curve then return false end
    local tcfg = ns.TrackerOf(w.cfg)
    local pt = tcfg and tcfg.power and ns.PowerTypes and ns.PowerTypes[tcfg.power]
    if not pt then return false end
    local r, g, b = ns.ColorCurve.EvalPower(tcfg.unit, pt, w._curve)
    if r then w.sb:SetStatusBarColor(r, g, b); return true end
    return false
end

-- Text for the SECRET path, honouring the chosen format without any Lua math on
-- the secret value: `value` is fed straight to SetFormattedText (accepts secrets);
-- `max` is readable for player power; the PERCENT comes from the engine
-- (UnitPowerPercent) — we never compute value/max ourselves (that would error).
local function setSecretText(w, value, max)
    local cfg = w.cfg
    local mode = cfg.textFormat or "valuemax"

    if mode == "percent" or mode == "valuepercent" then
        -- Engine gives a secret 0-100 (via a scalar curve); we never do the ×100.
        -- Both value and pct are secret — SetFormattedText takes them as-is.
        local tcfg = ns.TrackerOf(cfg)
        local pt   = tcfg and tcfg.power and ns.PowerTypes and ns.PowerTypes[tcfg.power]
        local pct  = pt and ns.ColorCurve and ns.ColorCurve.PowerPercent100 and ns.ColorCurve.PowerPercent100(tcfg.unit, pt)
        if pct then
            local fmt = (mode == "valuepercent") and "%d (%d%%)" or "%d%%"
            local a1  = (mode == "valuepercent") and value or pct
            if pcall(w.text.SetFormattedText, w.text, fmt, a1, pct) then return end
        end
    elseif mode == "valuemax" and not ns.IsSecret(max) then
        if pcall(w.text.SetFormattedText, w.text, "%d / %d", value, max) then return end
    end

    w.text:SetFormattedText("%d", value)   -- "value", or a safe fallback for the above
end

function Bar.Update(w, snap)
    local value, max = snap.value or 0, snap.max or 0

    -- "Glow when full": lit when a READABLE value reaches max. Secret values can't be compared,
    -- so a secret bar simply never glows. Evaluated before the render branches so it runs on
    -- every path (timer / segmented / secret / rich).
    local full = w.cfg.fullGlow and not ns.IsSecret(value) and not ns.IsSecret(max)
                 and max > 0 and value >= max
    Bar.SetFullGlow(w, full and true or false)

    -- Duration (timer) bar: an aura shown as a bar carries a readable remaining time, so drain
    -- the fill instead of showing a static 1/1. Not for resource (power) or stack (segments)
    -- bars — those fill by value/max. The OnUpdate ticker keeps it gliding between events.
    local dtr = ns.TrackerOf(w.cfg)
    local isTimer = not w.cfg.segments and not (dtr and dtr.type == "power")
        and snap.present ~= false and snap.duration and snap.expiration
        and not ns.IsSecret(snap.duration) and not ns.IsSecret(snap.expiration)
        and snap.duration > 0 and snap.expiration > GetTime()
    if isTimer then
        Animation.Cancel(w.id)
        w._durExp, w._durTotal = snap.expiration, snap.duration
        local rem = snap.expiration - GetTime()
        w.sb:SetMinMaxValues(0, snap.duration)
        w.sb:SetValue(rem)
        w.sb2:Hide()
        applyFillColor(w)
        updateSpark(w)
        w.text:SetText((w.cfg.showText ~= false) and fmtDur(rem) or "")
        return
    end
    w._durExp = nil   -- leaving timer mode (buff dropped / became a value bar)

    -- Segmented boxes: feed the value to each box (box i spans [i-1,i]); the engine fills exactly
    -- the covered ones — secret-safe, no Lua math on the value.
    if w._boxMode then
        if not ns.IsSecret(max) and max ~= w._segMax then w._segMax = max; Bar.LayoutBoxes(w) end
        local n = w._boxCount or 0
        if ns.IsSecret(value) then
            Animation.Cancel(w.id)
            for i = 1, n do w.segBoxes[i]:SetValue(value) end
            w._val = nil
            if w.spark then w.spark:Hide() end   -- can't place it without reading the value
        elseif w.cfg.split then
            -- 5+5 as boxes: two-tone per box (phase-1 backing + phase-2 fill), glided. Readable
            -- only (the split compares against `at`); sound fires on the real target, not `cur`.
            if ns.ColorCurve then ns.ColorCurve.Sounds(w, value, max) end
            local at = w.cfg.split.at or 5
            local from = w._val or 0
            Animation.To(w.id, from, value, smoothTime(w), function(cur)
                w._val = cur
                Bar.RenderSplitBoxes(w, cur, max)
                updateBoxSpark(w, cur > at and (cur - at) or cur)   -- spark rides the active phase's leading box
            end)
        else
            -- Readable (manual counters, runes…): glide the value so a box fills / drains smoothly,
            -- and ride the spark on whichever box is currently filling. Respects the Smooth toggle
            -- (smoothTime returns 0 when off → snaps).
            local from = w._val or 0
            Animation.To(w.id, from, value, smoothTime(w), function(cur)
                w._val = cur
                for i = 1, (w._boxCount or 0) do w.segBoxes[i]:SetValue(cur) end
                updateBoxSpark(w, cur)
            end)
            -- Colour + per-stop sound from the unified colour-stop curve (a count bar's stops are
            -- Step at count/max). No curve → boxes keep their base colour (set in LayoutBoxes).
            if ns.ColorCurve then
                ns.ColorCurve.Sounds(w, value, max)
                local tc = ns.ColorCurve.ColorAt(w.cfg, value, max)
                if tc then for i = 1, n do w.segBoxes[i]:SetStatusBarColor(tc.r, tc.g, tc.b, tc.a or 1) end end
            end
        end
        if w.cfg.showText ~= false then
            if ns.IsSecret(value) or ns.IsSecret(max) then setSecretText(w, value, max)
            else w.text:SetText(formatText(w.cfg, snap)) end
        else
            w.text:SetText("")
        end
        return
    end

    -- SetMinMaxValues / SetValue both accept secret values, so the bar fills
    -- correctly whether or not we're allowed to read the number ourselves.
    w.sb:SetMinMaxValues(0, ns.IsSecret(max) and max or (max > 0 and max or 1))
    w._lastMax = max                 -- so the SPELL_UPDATE_USABLE watcher can re-light markers
    -- Redraw segment boxes if the ceiling changed live (talent swap adds/removes a point).
    -- max is readable for player power even in combat, so this compare is safe.
    if w.cfg.segments and not ns.IsSecret(max) and max ~= w._segMax then
        w._segMax = max
        Bar.Segments(w)
    end
    Bar.Markers(w, max)

    if ns.IsSecret(value) or ns.IsSecret(max) then
        -- Secret path (player power is a secret even out of combat): no Lua
        -- math/compare/tostring — hand the secret straight to the widget. Colour
        -- comes from the ColorCurve (engine evaluates the secret %), else base.
        Animation.Cancel(w.id)
        w.sb:SetValue(value)
        applyFillColor(w)
        applyStateColor(w, snap)   -- tracker state colour (e.g. Void Metamorphosis) wins
        w._val = nil
        w.sb2:Hide()
        updateSpark(w)   -- spark rides the snapped edge — the one motion a secret bar can show
        if w.cfg.showText ~= false then
            setSecretText(w, value, max)           -- value / value-max / percent, secret-safe
        else
            w.text:SetText("")
        end
        return
    end

    -- Rich path (player data) for a CONTINUOUS bar — segmented bars (incl. the 5+5 split) render
    -- as boxes above and never reach here.
    w.sb2:Hide()
    local from = w._val or 0
    Animation.To(w.id, from, value, smoothTime(w), function(cur)
        w._val = cur
        w.sb:SetValue(cur)   -- spark is anchored to this fill texture, so it glides along
    end)
    -- Colour + per-stop sound from the colour-stop curve on a READABLE bar (Stagger's level, etc.):
    -- the engine path is power-only, so evaluate the curve in Lua at value/max.
    if w.cfg.colorCurve and max and max > 0 and ns.ColorCurve and ns.ColorCurve.EvalLua then
        local r, g, b = ns.ColorCurve.EvalLua(w.cfg.colorCurve, value / max)
        if r then w.sb:SetStatusBarColor(r, g, b) end
    end
    if ns.ColorCurve and ns.ColorCurve.Sounds then ns.ColorCurve.Sounds(w, value, max) end   -- per-stop pings (readable bars)
    applyStateColor(w, snap)   -- tracker state colour (e.g. Void Metamorphosis) wins
    updateSpark(w)

    if w.cfg.showText ~= false then
        w.text:SetText(formatText(w.cfg, snap))
    else
        w.text:SetText("")
    end
end
