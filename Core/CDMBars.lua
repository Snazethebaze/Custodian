-- Core/CDMBars.lua : restyle the native "Tracked Bars" viewer into a centered row
-- (or column) of ICONS.
--
-- Adopts Blizzard's own BuffBarCooldownViewer item frames (the ONLY thing that can
-- show a secret buff's live remaining time in combat) and visually converts each bar
-- into an icon + radial sweep + centered countdown, then lays the icons out centered
-- horizontally or vertically on the viewer's Edit-Mode position — like a group.
-- See mem:tracked-bars for the frame anatomy + the taint rules.
--
-- TAINT-SAFE, hard-won (see memory): we ONLY do passive frame writes (SetAlpha/
-- SetSize/SetPoint), POST-hooks, and our OWN child frames. We NEVER call the viewer's
-- Show()/RefreshLayout() or set hideWhenInactive — doing so runs Blizzard's secret
-- flow in our tainted context and floods errors across ALL cooldown viewers.
-- Positioning is CONTAINER-relative in the hooks (CMC's proven-stable pattern), NOT a
-- per-frame fight — individual free-drag was abandoned as unwinnable/flickery.

local ADDON, ns = ...

local CDMBars = {}
ns.CDMBars = CDMBars

CDMBars.size = 34          -- square icon size (px)
CDMBars.gap  = 4           -- spacing between icons (px)
CDMBars.dir  = "h"         -- "h" = centered row, "v" = centered column

local enabled = false      -- master toggle (session test flag; not yet persisted)
local hooked  = false      -- RefreshLayout hook installed once
local state   = setmetatable({}, { __mode = "k" })  -- per-item scratch, weak keys

local GetTime = GetTime

local function isSecret(v)  -- prefer our helper; fall back to the global
    if ns.IsSecret then return ns.IsSecret(v) end
    return _G.issecretvalue and _G.issecretvalue(v)
end

-- Floor-based countdown (same as Widgets/Icon.lua fmtCountdown): Blizzard's number
-- CEILS (reads ~1s long), so we show whole seconds remaining, one decimal under 3s.
local function fmtCountdown(s)
    if s < 3 then return string.format("%.1f", s) end
    if s < 60 then return string.format("%d", math.floor(s)) end
    return string.format("%dm", math.ceil(s / 60))
end

-- Readable expiration for the item's aura, or nil if secret/unavailable. isSecret can
-- false-negative on aura expirations, and comparing a secret ERRORS — so we actually
-- attempt the compare under pcall; if it throws, treat as secret → Blizzard's number.
local function readableExp(frame)
    local aid = frame.auraInstanceID
    if not aid or isSecret(aid) then return nil end
    if not (C_UnitAuras and C_UnitAuras.GetAuraDataByAuraInstanceID) then return nil end
    local ok, data = pcall(C_UnitAuras.GetAuraDataByAuraInstanceID, "player", aid)
    if not ok or type(data) ~= "table" then return nil end
    local exp = data.expirationTime
    if not exp then return nil end
    local safe, positive = pcall(function() return (exp - GetTime()) > 0 end)
    if not safe or not positive then return nil end
    return exp
end

-- Refresh one item's sweep + timer text on every hooked aura update.
-- SWEEP: opaque duration object → SetCooldownFromDurationObject (secret-safe).
-- TEXT: floored countdown if expiration is readable, else Blizzard's number.
local function refresh(frame)
    local st = state[frame]
    local cd = st and st.cd
    if not cd then return end

    if not enabled then cd:Clear(); st.timerExp = nil; if st.text then st.text:SetText("") end; return end

    local aid = frame.auraInstanceID
    if not aid or isSecret(aid) then
        cd:Clear(); st.timerExp = nil
        if st.text then st.text:SetText("") end
        return
    end

    if C_UnitAuras and C_UnitAuras.GetAuraDuration then
        local ok, dur = pcall(C_UnitAuras.GetAuraDuration, "player", aid)
        if ok and dur ~= nil then pcall(cd.SetCooldownFromDurationObject, cd, dur) else cd:Clear() end
    end

    local exp = readableExp(frame)
    if exp then
        st.timerExp = exp
        if cd.SetHideCountdownNumbers then cd:SetHideCountdownNumbers(true) end
        local rem = exp - GetTime()
        if st.text then st.text:SetText(rem > 0.05 and fmtCountdown(rem) or "") end
    else
        st.timerExp = nil
        if cd.SetHideCountdownNumbers then cd:SetHideCountdownNumbers(false) end
        if st.text then st.text:SetText("") end
    end
end

-- Create (once) our own Cooldown swipe + timer overlay on the item's icon host, and
-- hook the item's aura-update methods so the sweep/text/layout refresh live.
local function ensureCooldown(frame)
    local host = frame.Icon
    if not host then return end
    local st = state[frame]
    if st.cd then return st.cd end

    local cd = CreateFrame("Cooldown", nil, host, "CooldownFrameTemplate")
    cd:SetAllPoints(host)
    cd:SetDrawEdge(false)
    cd:SetDrawBling(false)
    cd:SetReverse(true)
    cd:SetHideCountdownNumbers(true)
    cd:SetFrameLevel(host:GetFrameLevel() + 8)
    st.cd = cd

    local overlay = CreateFrame("Frame", nil, host)
    overlay:SetAllPoints(host)
    overlay:SetFrameLevel(cd:GetFrameLevel() + 4)
    local text = overlay:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    text:SetPoint("CENTER", overlay, "CENTER", 0, 0)
    text:SetJustifyH("CENTER")
    st.overlay, st.text = overlay, text

    overlay:SetScript("OnUpdate", function(self, dt)
        local exp = st.timerExp
        if not exp then return end
        self._acc = (self._acc or 0) + dt
        if self._acc < 0.05 then return end
        self._acc = 0
        local rem = exp - GetTime()
        if rem <= 0.05 then text:SetText(""); st.timerExp = nil
        else text:SetText(fmtCountdown(rem)) end
    end)

    local fn = function()
        refresh(frame)
        -- Active-state changes alter which icons are shown → re-center the row.
        if enabled then CDMBars.Layout() end
    end
    st.drive = fn
    for _, m in ipairs({
        "OnUnitAuraAddedEvent", "OnUnitAuraUpdatedEvent", "OnUnitAuraRemovedEvent",
        "OnActiveStateChanged", "OnAuraInstanceInfoSet", "RefreshData",
    }) do
        -- pcall the hook: 12.1's Forbidden Aspects machinery may make hooking a CDM item
        -- method throw. If it does, we simply skip that hook rather than erroring the file.
        if type(frame[m]) == "function" then pcall(hooksecurefunc, frame, m, fn) end
    end
    return cd
end

-- Convert one bar item into an icon (position is handled centrally by Layout).
local function applyOne(frame)
    if not frame or not frame.Icon then return end
    local st = state[frame]; if not st then st = {}; state[frame] = st end

    if not st.orig then
        local host = frame.Icon
        st.orig = { fw = frame:GetWidth(), fh = frame:GetHeight(),
                    iw = host:GetWidth(), ih = host:GetHeight(), pts = {} }
        for i = 1, host:GetNumPoints() do st.orig.pts[i] = { host:GetPoint(i) } end
    end

    ensureCooldown(frame)
    if st.cd then st.cd:Show() end

    if frame.Bar then frame.Bar:SetAlpha(0) end
    if frame.DebuffBorder then frame.DebuffBorder:SetAlpha(0) end

    local s = CDMBars.size
    frame:SetSize(s, s)
    local host = frame.Icon
    host:SetSize(s, s)
    host:ClearAllPoints()
    host:SetPoint("CENTER", frame, "CENTER", 0, 0)

    st.applied = true
    refresh(frame)
end

-- Put one item back the way Blizzard had it.
local function restoreOne(frame)
    local st = state[frame]
    if not st or not st.applied then return end
    st.timerExp = nil
    if st.text then st.text:SetText("") end
    if st.cd then st.cd:Clear(); st.cd:Hide() end
    if frame.Bar then frame.Bar:SetAlpha(1) end
    if frame.DebuffBorder then frame.DebuffBorder:SetAlpha(1) end
    if st.orig then
        frame:SetSize(st.orig.fw, st.orig.fh)
        local host = frame.Icon
        if host then
            host:SetSize(st.orig.iw, st.orig.ih)
            host:ClearAllPoints()
            if #st.orig.pts > 0 then
                for _, p in ipairs(st.orig.pts) do host:SetPoint(unpack(p)) end
            else
                host:SetPoint("LEFT", frame, "LEFT", 0, 0)
            end
        end
    end
    st.applied = false
end

-- Lay the SHOWN icons out centered on the viewer, along the chosen axis. Container-
-- relative + hook-triggered = the CMC-proven stable pattern (no per-frame fight).
function CDMBars.Layout()
    if not enabled then return end
    local v = _G.BuffBarCooldownViewer
    if not (v and v.GetItemFrames) then return end
    local ok, items = pcall(v.GetItemFrames, v)
    if not ok or type(items) ~= "table" then return end

    local shown = {}
    for _, f in ipairs(items) do
        if f.Icon and f:IsShown() then shown[#shown + 1] = f end
    end
    table.sort(shown, function(a, b) return (a.layoutIndex or 0) < (b.layoutIndex or 0) end)

    local n = #shown
    if n == 0 then return end
    local step  = CDMBars.size + CDMBars.gap
    local total = (n - 1) * step
    local horiz = CDMBars.dir ~= "v"
    for i, f in ipairs(shown) do
        f:ClearAllPoints()
        if horiz then
            f:SetPoint("CENTER", v, "CENTER", -total / 2 + (i - 1) * step, 0)  -- left → right
        else
            f:SetPoint("CENTER", v, "CENTER", 0, total / 2 - (i - 1) * step)   -- top → bottom
        end
    end
end

function CDMBars.ApplyAll()
    local v = _G.BuffBarCooldownViewer
    if not (v and v.GetItemFrames) then return end
    local ok, items = pcall(v.GetItemFrames, v)
    if not ok or type(items) ~= "table" then return end
    for _, f in ipairs(items) do
        if enabled then applyOne(f) else restoreOne(f) end
    end
    if enabled then CDMBars.Layout() end
    -- NB: never call v:RefreshLayout() ourselves (taint). Restored bars re-settle on
    -- the next native layout pass.
end

-- Re-apply + re-center on every native layout pass (items are pooled; RefreshLayout
-- fires on add/remove/reorder). POST-hook only — we never invoke RefreshLayout.
local function ensureHook()
    if hooked then return end
    local v = _G.BuffBarCooldownViewer
    if not (v and v.RefreshLayout) then return end
    -- pcall the hook: 12.1's Forbidden Aspects could make hooking the viewer throw. On
    -- failure leave `hooked` false so a later ensureHook() can retry once the API settles.
    hooked = pcall(hooksecurefunc, v, "RefreshLayout", function()
        if enabled then CDMBars.ApplyAll() end
    end)
end

function CDMBars.SetEnabled(on)
    enabled = not not on
    if enabled then ensureHook() end
    CDMBars.ApplyAll()
    return enabled
end

function CDMBars.Toggle() return CDMBars.SetEnabled(not enabled) end

function CDMBars.SetSize(px)
    px = tonumber(px)
    if not px or px < 8 or px > 128 then return CDMBars.size end
    CDMBars.size = px
    if enabled then CDMBars.ApplyAll() end
    return CDMBars.size
end

function CDMBars.SetGap(px)
    px = tonumber(px)
    if not px or px < -20 or px > 100 then return CDMBars.gap end
    CDMBars.gap = px
    if enabled then CDMBars.Layout() end
    return CDMBars.gap
end

function CDMBars.SetDir(dir)
    if dir == "h" or dir == "v" then CDMBars.dir = dir
    else CDMBars.dir = (CDMBars.dir == "h") and "v" or "h" end   -- toggle if unspecified
    if enabled then CDMBars.Layout() end
    return CDMBars.dir
end
