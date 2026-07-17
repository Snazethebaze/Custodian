-- Widgets/Icon.lua : the "icon" display — a spell icon with a cooldown sweep
-- and a stack count. Ideal for maintained buffs (Earth/Lightning Shield),
-- procs and cooldowns.
--
-- Secret-safe: the sweep uses SetCooldownFromExpirationTime (which accepts
-- secret durations), and the count is passed straight to SetFormattedText.

local ADDON, ns = ...
local Media = ns.Media

local Icon = {}
ns.RegisterDisplay("icon", Icon)

local FALLBACK_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"
local GetTime = GetTime

-- Our OWN countdown text. Blizzard's cooldown number CEILS (shows "12" with 11.x
-- left, "1" for the whole final second) — which reads ~1s long. Shared with bars so a buff reads
-- the same on both: whole seconds/minutes floored (never reads late), one decimal in the last 3 s.
local fmtCountdown = ns.FormatRemaining

-- Icon text sits 2px off the corner (see ns.TextAnchor in Widgets/Widget.lua).
local function textAnchor(a, default) return ns.TextAnchor(a, default, 2) end

-- Native glows from LibCustomGlow (the familiar Blizzard-style effects) as an
-- alternative to our art-agnostic texture glows. Feature-detected + pcall-guarded so
-- a missing lib never errors. Keyed by cfg.glowStyle; nil = one of the texture styles.
local LCG = LibStub and LibStub("LibCustomGlow-1.0", true)
local NATIVE_GLOW = LCG and {
    pixel    = { start = LCG.PixelGlow_Start,    stop = LCG.PixelGlow_Stop },
    autocast = { start = LCG.AutoCastGlow_Start, stop = LCG.AutoCastGlow_Stop },
    proc     = { start = LCG.ProcGlow_Start,     stop = LCG.ProcGlow_Stop },
    blizzard = { start = LCG.ButtonGlow_Start,   stop = LCG.ButtonGlow_Stop },
} or {}

-- The native LibCustomGlow dispatch, in ONE place so the whole-widget glow (Icon.SetAlert) and the
-- per-pip glow (pipGlow) can't drift on the fragile bits: the Proc special case (ProcGlow wants
-- { color = {…} }, the others a raw {r,g,b,a}) and the pcall guard (LCG pool objects throw on a bad
-- call). Callers still own their own _lcgStyle/_glowCur tracking (they differ). startNativeGlow
-- returns true if `style` is a native one (so the caller knows to record it).
local function startNativeGlow(frame, style, color)
    local nat = NATIVE_GLOW[style or ""]
    if not (nat and nat.start) then return false end
    local col = { color.r, color.g, color.b, color.a or 1 }
    if style == "proc" then pcall(nat.start, frame, { color = col }) else pcall(nat.start, frame, col) end
    return true
end
local function stopNativeGlowStyle(frame, style)
    local nat = style and NATIVE_GLOW[style]
    if nat and nat.stop then pcall(nat.stop, frame) end
end

-- Stop ONLY the native glow that's actually running (tracked by _lcgStyle), and only
-- once (guarded by _lcgOn) — calling every Stop unconditionally, or twice, makes
-- LibCustomGlow double-release a pool object ("doesn't belong to this pool").
local function stopNativeGlow(w)
    if LCG and w._lcgOn then stopNativeGlowStyle(w.frame, w._lcgStyle) end
    w._lcgOn = false
    w._lcgStyle = nil
end

-- The "louder reminder" glow pulses only while a missing/expiring reminder is
-- actually on screen — in "missing" mode the icon is shown ONLY then — and only
-- if the widget opted in (cfg.pulse, default on).
-- The effective reminder mode: the newer cfg.reminder.mode wins, else the legacy cfg.showWhen.
-- The glow used to read ONLY showWhen, so a reminder configured via the editor's Reminder
-- dropdown (which sets reminder.mode, not showWhen) SHOWED but never glowed — matching
-- ReminderVisible here keeps the halo in lockstep with the icon's visibility.
local function remMode(cfg) return (cfg.reminder and cfg.reminder.mode) or cfg.showWhen end

local function alertActive(w)
    return remMode(w.cfg) == "missing" and w.cfg.pulse ~= false and w.frame and w.frame:IsShown()
end

-- Show/hide the glow. `pulse` = breathe (missing-buff reminder); otherwise a STEADY
-- glow (the "active / ready" indicator) — shown at full alpha, no animation.
-- A native (LibCustomGlow) style is driven directly on the icon frame; the texture
-- styles (outline/fill/border) use our alertFrame + pulse animation.
function Icon.SetAlert(w, on, pulse)
    local native = NATIVE_GLOW[w.cfg.glowStyle or ""]
    if native then
        -- our texture glow must be off when a native one is in charge
        if w.alertFrame then if w.pulseAG then w.pulseAG:Stop() end; w.alertFrame:Hide() end
        if on then
            -- (re)start when not running OR the chosen style changed — otherwise every
            -- native style would keep whichever one started first (they'd look identical).
            if not w._lcgOn or w._lcgStyle ~= w.cfg.glowStyle then
                stopNativeGlow(w)
                startNativeGlow(w.frame, w.cfg.glowStyle, w._glowColor or { r = 1, g = 0.15, b = 0.15 })
                w._lcgOn = true
                w._lcgStyle = w.cfg.glowStyle
            end
        else
            stopNativeGlow(w)
        end
        return
    end
    stopNativeGlow(w)   -- switched away from a native style
    if not w.alertFrame then return end
    if on then
        w.alertFrame:Show()
        if pulse then
            if w.pulseAG and not w.pulseAG:IsPlaying() then w.pulseAG:Play() end
        else
            if w.pulseAG and w.pulseAG:IsPlaying() then w.pulseAG:Stop() end
            w.alertFrame:SetAlpha(1)
        end
    else
        if w.pulseAG then w.pulseAG:Stop() end
        w.alertFrame:Hide()
    end
end

-- Frame the icon with four bars sitting `o` px outside its edge, `t` px thick —
-- the "outline" glow. Art-agnostic (unlike the button-border texture), so it looks
-- clean on any icon set, custom or default.
local function layoutGlowEdges(w)
    local e, f, t, o = w.glowEdges, w.frame, 3, 2
    e.TOP:ClearAllPoints()
    e.TOP:SetPoint("BOTTOMLEFT",  f, "TOPLEFT",  -o,  o); e.TOP:SetPoint("BOTTOMRIGHT", f, "TOPRIGHT",  o,  o); e.TOP:SetHeight(t)
    e.BOTTOM:ClearAllPoints()
    e.BOTTOM:SetPoint("TOPLEFT",  f, "BOTTOMLEFT", -o, -o); e.BOTTOM:SetPoint("TOPRIGHT", f, "BOTTOMRIGHT",  o, -o); e.BOTTOM:SetHeight(t)
    e.LEFT:ClearAllPoints()
    e.LEFT:SetPoint("TOPRIGHT",    f, "TOPLEFT",  -o,  o); e.LEFT:SetPoint("BOTTOMRIGHT", f, "BOTTOMLEFT", -o, -o); e.LEFT:SetWidth(t)
    e.RIGHT:ClearAllPoints()
    e.RIGHT:SetPoint("TOPLEFT",     f, "TOPRIGHT",  o,  o); e.RIGHT:SetPoint("BOTTOMLEFT", f, "BOTTOMRIGHT",  o, -o); e.RIGHT:SetWidth(t)
end

function Icon.Create(w)
    local f = w.frame

    local tex = f:CreateTexture(nil, "ARTWORK")
    tex:SetPoint("TOPLEFT", f, "TOPLEFT", 1, -1)
    tex:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -1, 1)
    tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)   -- trim the default icon border
    w.icon = tex

    local cd = CreateFrame("Cooldown", nil, f, "CooldownFrameTemplate")
    cd:SetPoint("TOPLEFT", f, "TOPLEFT", 1, -1)
    cd:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -1, 1)
    cd:SetDrawEdge(false)
    w.cd = cd

    -- Tick our own countdown text between tracker events (throttled). Runs only while
    -- w._timerExp is set (a readable expiry); idle-cheap otherwise.
    f:SetScript("OnUpdate", function(self, dt)
        local exp = w._timerExp
        if not exp then return end
        self._cdAcc = (self._cdAcc or 0) + dt
        if self._cdAcc < 0.05 then return end
        self._cdAcc = 0
        local rem = exp - GetTime()
        if rem <= 0.05 then w.text:SetText(""); w._timerExp = nil
        else w.text:SetText(fmtCountdown(rem)) end
    end)

    w.edges = ns.MakeEdges(f, "OVERLAY", 0, 0, 0, 1)

    -- The count / countdown text lives on its own frame ABOVE the cooldown frame, so
    -- it's never buried under the sweep's dark swipe (a child Cooldown frame draws over
    -- the parent's own font strings).
    local textHost = CreateFrame("Frame", nil, f)
    textHost:SetAllPoints(f)
    textHost:SetFrameLevel(cd:GetFrameLevel() + 5)
    local count = textHost:CreateFontString(nil, "OVERLAY")
    w.text = count

    -- Attention glow for the missing/expiring reminder — a halo that breathes via an
    -- engine-driven looping alpha (no per-frame Lua) so it's easy to catch. Three
    -- styles are built here; ApplyStyle shows the one cfg.glowStyle picks. "outline"
    -- and "fill" are art-agnostic; "border" is the Blizzard action-button look.
    local af = CreateFrame("Frame", nil, f)
    af:SetAllPoints(f)
    af:SetFrameLevel(f:GetFrameLevel() + 6)
    af:Hide()
    w.alertFrame = af

    -- border: the classic UI-ActionButton-Border blob (sized larger than the icon).
    local blob = af:CreateTexture(nil, "OVERLAY")
    blob:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
    blob:SetBlendMode("ADD")
    blob:SetPoint("CENTER")
    w.glowBorder = blob

    -- fill: a soft colour wash over the whole icon (ADD).
    local fill = af:CreateTexture(nil, "ARTWORK")
    fill:SetAllPoints(af)
    fill:SetColorTexture(1, 1, 1, 0.32)
    fill:SetBlendMode("ADD")
    w.glowFill = fill

    -- outline: four tinted bars framing the icon just outside its edge.
    w.glowEdges = ns.MakeEdges(af, "OVERLAY", 1, 1, 1, 1)

    local grp = af:CreateAnimationGroup(); grp:SetLooping("BOUNCE")
    local a = grp:CreateAnimation("Alpha")
    a:SetFromAlpha(1.0); a:SetToAlpha(0.15); a:SetDuration(0.55)
    w.pulseAG = grp

    -- In "missing" mode the frame is shown only while reminding, so tie the pulse
    -- to visibility: start on show, stop on hide.
    f:HookScript("OnShow", function()
        if remMode(w.cfg) == "missing" then Icon.SetAlert(w, alertActive(w), true) end
        -- the steady "active / ready" glow is driven by Icon.Update, not on show.
    end)
    f:HookScript("OnHide", function() Icon.SetAlert(w, false) end)
end

-- "One icon per charge" mode (Survival Tip of the Spear, etc.): draw `n` pips in a horizontal row
-- instead of a single icon + count, each the tracker's icon, lit up to the count. The pips DIVIDE
-- the widget's own width × height (both Size sliders affect every pip equally), each carrying the
-- widget's border, and — when "Glow while active" is on — an activation glow on the LIT ones.
-- Each pip is a small Frame (so it can hold a border + a LibCustomGlow) rather than a bare texture.
local PIP_GAP = ns.SEG_GAP_DEFAULT   -- shared default gap so bar boxes and icon pips match

-- Per-pip glow that HONOURS the widget's chosen Effect style (native LibCustomGlow ones — Pixel /
-- Autocast / Proc / Blizzard — plus our texture Fill / Outline), so switching the effect actually
-- changes it. Tracks the active style on the pip so it only restarts when the style changes.
local function pipStopGlow(p)
    if p._lcgStyle then
        stopNativeGlowStyle(p, p._lcgStyle)
        p._lcgStyle = nil
    end
    if p._glowFill then p._glowFill:Hide() end
    if p._glowEdges then for _, t in pairs(p._glowEdges) do t:Hide() end end
    p._glowCur = nil
end
local function pipGlow(p, on, style, color)
    if not on then
        if p._glowCur or p._lcgStyle then pipStopGlow(p) end
        return
    end
    style = style or "proc"
    color = color or { r = 0.25, g = 1, b = 0.35 }
    if p._glowCur == style then return end   -- already showing this exact style
    pipStopGlow(p)
    if startNativeGlow(p, style, color) then
        p._lcgStyle = style
    elseif style == "fill" then
        if not p._glowFill then
            p._glowFill = p:CreateTexture(nil, "OVERLAY"); p._glowFill:SetAllPoints(p); p._glowFill:SetBlendMode("ADD")
        end
        p._glowFill:SetColorTexture(color.r, color.g, color.b, 0.35); p._glowFill:Show()
    else   -- "outline" / "border" / unknown → a coloured outline on the pip
        if not p._glowEdges then p._glowEdges = ns.MakeEdges(p, "OVERLAY", 1, 1, 1, 1) end
        ns.LayoutEdges(p._glowEdges, p, 2)
        for _, t in pairs(p._glowEdges) do t:SetColorTexture(color.r, color.g, color.b, 0.9); t:Show() end
    end
    p._glowCur = style
end
local function ensurePips(w, n)
    w._pips = w._pips or {}
    for i = 1, n do
        if not w._pips[i] then
            local p = CreateFrame("Frame", nil, w.frame)
            p.icon = p:CreateTexture(nil, "ARTWORK")
            p.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)   -- trim the default icon border
            p._edges = ns.MakeEdges(p, "OVERLAY", 0, 0, 0, 1)
            w._pips[i] = p
        end
    end
    return w._pips
end
function Icon.LayoutPips(w, n)
    local cfg = w.cfg
    local W, H = cfg.width or 120, cfg.height or 40
    local gap = cfg.segmentGap or PIP_GAP
    local pipW = ns.CellWidth(W, n, gap)
    ensurePips(w, n)
    for i = 1, n do
        local p = w._pips[i]
        p:ClearAllPoints()
        p:SetSize(pipW, H)
        p:SetPoint("TOPLEFT", w.frame, "TOPLEFT", (i - 1) * (pipW + gap), 0)
        local bth = ns.ApplyBorder(p._edges, p, cfg)   -- per-pip border (thickness/colour from cfg)
        local ins = math.max(bth, 0)
        p.icon:ClearAllPoints()
        p.icon:SetPoint("TOPLEFT", p, "TOPLEFT", ins, -ins)
        p.icon:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", -ins, ins)
        p:Show()
    end
    for i = n + 1, #w._pips do local p = w._pips[i]; pipGlow(p, false); p:Hide() end
end

-- How many pips this widget's tracker maxes at (Tip = 3). Shared with bar boxes via
-- ns.SegmentCount; falls back to any existing pips, then 3.
local function pipCount(w)
    local fb = (w._pips and #w._pips) or 3
    return ns.SegmentCount(w.cfg, fb) or fb
end

-- Hide/stop every pip (leaving charge mode, destroy) so no LibCustomGlow is orphaned.
local function clearPips(w)
    if not w._pips then return end
    for _, p in ipairs(w._pips) do pipGlow(p, false); p:Hide() end
end

-- Style for charge-pip mode: hide the single-icon furniture (icon/cd/text/whole-frame border/glow)
-- and lay the pips out across the widget's W × H. Frame size stays what the generic ApplyStyle set,
-- so the Size sliders drive the pips.
function Icon.ApplyChargeStyle(w)
    -- Hide (don't SetText) the count string: this runs during Widget.New before the font is set,
    -- and SetText on a font-less FontString errors ("Font not set"). Hide needs no font.
    w.icon:Hide(); w.cd:Clear(); w.cd:Hide(); w.text:Hide()
    for _, t in pairs(w.edges) do t:Hide() end   -- the whole-frame border is replaced by per-pip ones
    if w.alertFrame then Icon.SetAlert(w, false); w.alertFrame:Hide() end
    Icon.LayoutPips(w, pipCount(w))
    -- Re-apply the last snapshot so a config change (effect style/colour, size, border) shows on the
    -- pips immediately, instead of waiting for the next tracker tick.
    if w.snap then Icon.UpdateCharges(w, w.snap) end
end

function Icon.ApplyStyle(w)
    local cfg = w.cfg
    if cfg.segments then Icon.ApplyChargeStyle(w); return end   -- "Segmented" icon = one pip per charge
    -- Not (or no longer) in charge mode: restore the single icon, hide/stop any pips.
    w.icon:Show(); w.cd:Show()
    clearPips(w)
    ns.SetFontReflow(w.text, Media.Font(cfg.font), cfg.fontSize or 14, "OUTLINE")
    local ap, bx, by, jh = textAnchor(cfg.textAnchor, "BOTTOMRIGHT")
    w.text:ClearAllPoints()
    w.text:SetPoint(ap, w.frame, ap, bx + (cfg.textOffsetX or 0), by + (cfg.textOffsetY or 0))
    w.text:SetJustifyH(jh)
    w.text:SetShown(cfg.showText ~= false)
    -- Configurable border (thickness + colour, 0 = none). Inset the icon art + cooldown
    -- sweep by the thickness so the frame sits around the art, not over it.
    local bth = ns.ApplyBorder(w.edges, w.frame, cfg)
    local ins = math.max(bth, 0)
    w.icon:ClearAllPoints(); w.icon:SetPoint("TOPLEFT", w.frame, "TOPLEFT", ins, -ins); w.icon:SetPoint("BOTTOMRIGHT", w.frame, "BOTTOMRIGHT", -ins, ins)
    w.cd:ClearAllPoints();   w.cd:SetPoint("TOPLEFT", w.frame, "TOPLEFT", ins, -ins);   w.cd:SetPoint("BOTTOMRIGHT", w.frame, "BOTTOMRIGHT", -ins, ins)

    -- Glow: two purposes share the same textures/styles, coloured by mode —
    --   · "missing" reminder -> a PULSING glow (default red) while the reminder shows
    --   · otherwise + cfg.activeGlow -> a STEADY glow (default green) while active/ready
    -- One widget is only ever one mode, so the colour is picked here.
    if w.alertFrame then
        local style = cfg.glowStyle or "outline"
        local isMissing = remMode(cfg) == "missing"
        local pc = isMissing and (cfg.pulseColor or { r = 1, g = 0.15, b = 0.15 })
                              or (cfg.activeGlowColor or { r = 0.25, g = 1, b = 0.35 })
        w._glowColor = pc   -- SetAlert colours the native (LibCustomGlow) styles from this
        -- Stop any running native glow so a style/colour change (this is a config edit)
        -- takes effect cleanly; the SetAlert below restarts it fresh with the new values.
        stopNativeGlow(w)
        w.glowBorder:Hide(); w.glowFill:Hide()
        for _, t in pairs(w.glowEdges) do t:Hide() end
        if style == "border" then
            w.glowBorder:SetSize((cfg.width or 40) * 1.6, (cfg.height or 40) * 1.6)
            w.glowBorder:SetVertexColor(pc.r, pc.g, pc.b); w.glowBorder:Show()
        elseif style == "fill" then
            w.glowFill:SetVertexColor(pc.r, pc.g, pc.b); w.glowFill:Show()
        else   -- "outline"
            layoutGlowEdges(w)
            for _, t in pairs(w.glowEdges) do t:SetVertexColor(pc.r, pc.g, pc.b); t:Show() end
        end
        if isMissing then
            Icon.SetAlert(w, alertActive(w), true)
        else
            -- steady active/ready glow: reflect the last snapshot right away
            local snap = w.snap
            local bright = snap and (snap.active ~= false) and (snap.ready ~= false)
            Icon.SetAlert(w, (cfg.activeGlow and bright) and true or false, false)
        end
    end
end

-- Charge-pip update: light pips 1..count (readable estimate; Tip's count is never secret), dim
-- the rest. Relayouts if the ceiling grew since ApplyStyle.
function Icon.UpdateCharges(w, snap)
    local icon = snap.icon
    if not icon or ns.IsSecret(icon) then icon = FALLBACK_ICON end
    local n = snap.max
    if ns.IsSecret(n) or type(n) ~= "number" or n < 1 then n = pipCount(w) end
    if not w._pips or #w._pips < n then Icon.LayoutPips(w, n) end
    local cnt = snap.count
    local readable = cnt and not ns.IsSecret(cnt)
    local wantGlow = w.cfg.activeGlow and true or false   -- glow the LIT pips when the user wants it
    local gStyle   = w.cfg.glowStyle
    local gColor   = w.cfg.activeGlowColor or { r = 0.25, g = 1, b = 0.35 }
    for i = 1, n do
        local p = w._pips[i]
        if p then
            p.icon:SetTexture(icon)
            local lit = readable and (cnt >= i)
            p.icon:SetDesaturated(not lit)
            p:SetAlpha(lit and 1 or 0.30)
            p:Show()
            pipGlow(p, lit and wantGlow, gStyle, gColor)
        end
    end
    for i = n + 1, (w._pips and #w._pips or 0) do local p = w._pips[i]; pipGlow(p, false); p:Hide() end
end

function Icon.Update(w, snap)
    if w.cfg.segments then Icon.UpdateCharges(w, snap); return end
    local icon = snap.icon
    if not icon or ns.IsSecret(icon) then icon = FALLBACK_ICON end
    w.icon:SetTexture(icon)

    local active = snap.active ~= false   -- power trackers have no `active`; treat as on
    -- `ready == false` (a cooldown-style snapshot) dims the icon. The cooldown reader is
    -- still loaded and sets `ready`, but the wizard/editor no longer offers the cooldown
    -- kind (no reliable standalone in-combat readout in Midnight — see mem:midnight-secrets),
    -- so only legacy profiles feed it.
    local dim = (snap.ready == false)
    if remMode(w.cfg) == "missing" then
        -- a "missing" reminder only appears when the buff is down, so it should be
        -- bright/alert, not the usual dimmed-when-inactive look.
        w.icon:SetDesaturated(false); w.frame:SetAlpha(1)
    else
        w.icon:SetDesaturated((not active) or dim)
        w.frame:SetAlpha((active and not dim) and 1 or 0.4)
        -- Steady "active / ready" glow: lit while the buff is up (aura) or the ability
        -- is off cooldown. Keys off the real ready flag (not the optional `dim`), so it
        -- still means "ready" even when the icon isn't set to desaturate on cooldown.
        if w.alertFrame then
            local ready = snap.ready ~= false
            Icon.SetAlert(w, (w.cfg.activeGlow and active and ready) and true or false, false)
        end
    end

    local cd = w.cd
    if active and snap.cdDuration then
        -- cooldown-style: raw start + duration (secret in 12.0), fed straight in.
        -- SetCooldown accepts secrets; pcall in case a future client tightens it.
        pcall(cd.SetCooldown, cd, snap.cdStart, snap.cdDuration)
    elseif active and snap.duration and snap.expiration then
        -- aura-style: expiration + duration.
        if cd.SetCooldownFromExpirationTime then
            pcall(cd.SetCooldownFromExpirationTime, cd, snap.expiration, snap.duration)   -- accepts secrets; pcall in case a future client tightens it (matches SetCooldown above)
        elseif not ns.IsSecret(snap.expiration) and not ns.IsSecret(snap.duration) then
            cd:SetCooldown(snap.expiration - snap.duration, snap.duration)
        end
    else
        cd:Clear()
    end

    -- The centre text is EITHER a stack count (MSW: 2+) OR our own countdown for a
    -- timed buff. A real stack wins; otherwise, if there's a readable expiry, we show
    -- the accurate countdown (and hide Blizzard's ceil number so they don't fight).
    local cnt = snap.count
    local realStacks = cnt and not ns.IsSecret(cnt) and cnt > 1
    local exp = snap.expiration
    local showTimer = active and w.cfg.showText ~= false and exp and not ns.IsSecret(exp) and not realStacks
    if cd.SetHideCountdownNumbers then
        -- Hide Blizzard's ceil number when we draw our own, or when text is off entirely.
        cd:SetHideCountdownNumbers((showTimer or w.cfg.showText == false) and true or false)
    end
    if showTimer then
        w._timerExp = exp
        local rem = exp - GetTime()
        w.text:SetText(rem > 0.05 and fmtCountdown(rem) or "")
    else
        w._timerExp = nil
        if w.cfg.showText ~= false and active and not snap.noCount and cnt and (ns.IsSecret(cnt) or cnt > 0) then
            w.text:SetFormattedText("%d", cnt)   -- secret count shown as-is (can't test it)
        else
            w.text:SetText("")
        end
    end
end

-- Release any native glow when the widget is torn down (spec change recreates widgets,
-- deletion, …) so its LibCustomGlow pool object doesn't leak.
function Icon.Destroy(w)
    stopNativeGlow(w)
end
