-- Core/ColorCurve.lua : secret-safe "colour the bar by its fill" for power bars.
--
-- A secret power value can't be compared in Lua, so we can't pick a colour with
-- `if pct < 0.3 then red`. Instead we hand the ENGINE a colour curve and ask it
-- to evaluate the (secret) power percent against it — it returns a colour, and
-- the addon never sees the number. Elemental heats toward cap, Resto goes red
-- when low. Every call is feature-detected + pcall-guarded: if the 12.0 API
-- isn't there, this all no-ops and the bar keeps its base colour.

local ADDON, ns = ...

local CC = {}
ns.ColorCurve = CC

function CC.Available()
    return (C_CurveUtil and C_CurveUtil.CreateColorCurve and UnitPowerPercent and CreateColor) and true or false
end

-- Generic low -> high ramp (red -> yellow -> green). Reads as "fuller is better"
-- for a building resource and "low = danger" for mana, so it suits both.
function CC.DefaultPoints()
    return {
        { pct = 0.0, color = { r = 0.85, g = 0.20, b = 0.20 } },
        { pct = 0.5, color = { r = 0.95, g = 0.85, b = 0.25 } },
        { pct = 1.0, color = { r = 0.30, g = 0.85, b = 0.40 } },
    }
end

-- Build a live ColorCurve from a { type, points } config, or nil if unavailable.
-- We ALWAYS drive the engine as Linear. "Step" is emulated by pre-expanding the
-- points — a duplicate of each colour placed just before the next stop — so linear
-- interpolation snaps hard instead of blending. The engine's native Step type
-- didn't take on 12.0.7, and this is exact, and still fully secret-safe (the engine
-- evaluates the secret %; we only ever hand it plain config numbers).
function CC.Build(curveCfg)
    if not curveCfg or not curveCfg.points or #curveCfg.points == 0 then return nil end
    if not (C_CurveUtil and C_CurveUtil.CreateColorCurve and CreateColor) then return nil end
    local ok, cc = pcall(C_CurveUtil.CreateColorCurve)
    if not ok or not cc then return nil end
    if cc.SetType then pcall(cc.SetType, cc, "Linear") end

    -- Sort a COPY ascending by fill % (the editor's row order is left alone).
    local pts = {}
    for _, p in ipairs(curveCfg.points) do pts[#pts + 1] = p end
    table.sort(pts, function(a, b) return (a.pct or 0) < (b.pct or 0) end)

    -- "Step": hold each colour until just shy of the next stop, then hard-snap.
    local use = pts
    if curveCfg.type == "Step" and #pts >= 2 then
        use = {}
        local EPS = 0.003
        for i, p in ipairs(pts) do
            use[#use + 1] = { pct = p.pct or 0, color = p.color }
            local nxt = pts[i + 1]
            if nxt then
                local hold = (nxt.pct or 0) - EPS
                if hold > (p.pct or 0) then use[#use + 1] = { pct = hold, color = p.color } end
            end
        end
    end

    -- Clamp the domain to [0,1] so the ends hold their colour instead of
    -- extrapolating past the last stop (e.g. green stays green all the way to full).
    if (use[1].pct or 0) > 0 then table.insert(use, 1, { pct = 0, color = use[1].color }) end
    local last = use[#use]
    if (last.pct or 0) < 1 then use[#use + 1] = { pct = 1, color = last.color } end

    for _, p in ipairs(use) do
        local c = p.color or {}
        pcall(cc.AddPoint, cc, p.pct or 0, CreateColor(c.r or 1, c.g or 1, c.b or 1, c.a or 1))
    end
    return cc
end

-- Percent-as-text for a SECRET power bar. UnitPowerPercent returns a 0-1 fraction
-- (secret), and we can't ×100 it in Lua (math on a secret errors). So we hand the
-- engine a SCALAR curve mapping 0->0, 1->100 and let IT do the multiply — the
-- return is a secret 0-100 we feed straight to SetFormattedText. The scalar-curve
-- constructor's name isn't certain across builds, so we try the plausible ones
-- (and `/cust curve` dumps what's really there). Returns the secret number or nil.
local pctCurve
local function buildPctCurve()
    if not C_CurveUtil then return nil end
    for _, ctor in ipairs({ "CreateCurve", "CreateScalarCurve", "CreateFloatCurve",
                            "CreateNumericCurve", "CreateNumberCurve", "CreateValueCurve" }) do
        local fn = C_CurveUtil[ctor]
        if type(fn) == "function" then
            local ok, c = pcall(fn)
            -- curves are USERDATA, not tables (that guard silently dropped them);
            -- accept anything truthy with an AddPoint method.
            if ok and c and c.AddPoint then
                if c.SetType then pcall(c.SetType, c, "Linear") end
                local a1 = pcall(c.AddPoint, c, 0, 0)
                local a2 = pcall(c.AddPoint, c, 1, 100)
                if a1 and a2 then return c end
            end
        end
    end
    return nil
end

function CC.PowerPercent100(unit, powerType)
    if not (UnitPowerPercent and powerType) then return nil end
    if pctCurve == nil then pctCurve = buildPctCurve() or false end
    if not pctCurve then return nil end
    local ok, v = pcall(UnitPowerPercent, unit or "player", powerType, false, pctCurve)
    if ok and v then return v end   -- secret 0-100 (a Color here would mean the curve was ignored)
    return nil
end

-- Evaluate the curve against a player power type; returns r,g,b (or nil). The
-- engine reads the secret percent and returns a colour — the addon never does.
function CC.EvalPower(unit, powerType, curve)
    if not curve or not UnitPowerPercent or not powerType then return nil end
    local ok, a, b, c = pcall(UnitPowerPercent, unit or "player", powerType, false, curve)
    if not ok then return nil end
    if type(a) == "table" and a.GetRGB then return a:GetRGB() end
    if type(a) == "number" then return a, b, c end
    return nil
end

-- Evaluate a colour-curve CONFIG in pure Lua at a readable fill fraction (0..1). For bars whose
-- value we CAN read (Stagger = UnitStagger/maxHP, readable stacks…), where the engine's secret
-- power-percent path doesn't apply. Linear interpolates between stops; Step holds each colour to
-- the next stop. Returns r,g,b (or nil). Never touches a secret value.
function CC.EvalLua(curveCfg, pct)
    if not (curveCfg and curveCfg.points and #curveCfg.points > 0) then return nil end
    if type(pct) ~= "number" then return nil end
    if pct < 0 then pct = 0 elseif pct > 1 then pct = 1 end
    local pts = {}
    for _, p in ipairs(curveCfg.points) do pts[#pts + 1] = p end
    table.sort(pts, function(a, b) return (a.pct or 0) < (b.pct or 0) end)
    -- Step: the colour of the highest stop AT OR BELOW the fill — matches the old ns.ThresholdColor
    -- (highest count met) and the engine's snap-at-stop, so a migrated count bar reads identically.
    if curveCfg.type == "Step" then
        local col = pts[1].color or {}
        for _, p in ipairs(pts) do if (p.pct or 0) <= pct then col = p.color or col else break end end
        return col.r or 1, col.g or 1, col.b or 1
    end
    if pct <= (pts[1].pct or 0) then local c = pts[1].color or {}; return c.r or 1, c.g or 1, c.b or 1 end
    local last = pts[#pts]
    if pct >= (last.pct or 0) then local c = last.color or {}; return c.r or 1, c.g or 1, c.b or 1 end
    for i = 1, #pts - 1 do
        local a, b = pts[i], pts[i + 1]
        local ap, bp = a.pct or 0, b.pct or 0
        if pct >= ap and pct <= bp then
            local ac, bc = a.color or {}, b.color or {}   -- Linear only (Step returned above)
            local t = (bp > ap) and (pct - ap) / (bp - ap) or 0
            return (ac.r or 1) + ((bc.r or 1) - (ac.r or 1)) * t,
                   (ac.g or 1) + ((bc.g or 1) - (ac.g or 1)) * t,
                   (ac.b or 1) + ((bc.b or 1) - (ac.b or 1)) * t
        end
    end
    return nil
end

-- Colour at a readable value as a {r,g,b} table (or nil) — what the box / count render paths want
-- (the old ns.ThresholdColor shape). Continuous bars call EvalLua directly for r,g,b. Caller must
-- pass a READABLE value/max (never divides a secret).
function CC.ColorAt(cfg, value, max)
    if not (cfg and cfg.colorCurve) or not max or max <= 0 then return nil end
    local r, g, b = CC.EvalLua(cfg.colorCurve, value / max)
    if r then return { r = r, g = g, b = b } end
    return nil
end

-- Per-stop SOUND for a readable colour-stop bar: fire a stop's sound when the readable value
-- crosses its position (pct × max) upward. Secret bars (power fills) can't be compared in Lua, so
-- they never sound — this bails, mirroring ns.ThresholdSounds. Tracks the previous value on the
-- widget so a crossing is a real prev<at<=now transition, not a re-fire while sitting above it.
function CC.Sounds(w, value, max)
    local cc = w.cfg.colorCurve
    if not cc or not cc.points or value == nil or max == nil
       or ns.IsSecret(value) or ns.IsSecret(max) or max <= 0 then
        w._prevCurveVal = nil
        return
    end
    local prev = w._prevCurveVal
    if prev then
        for _, p in ipairs(cc.points) do
            if p.sound and p.pct then
                local at = p.pct * max
                if prev < at and value >= at then ns.PlaySound(p.sound) end
            end
        end
    end
    w._prevCurveVal = value
end

-- One-time fold of legacy cfg.thresholds (count+colour+sound) into cfg.colorCurve: a Step stop at
-- count/max for each, with the bar's BASE colour pinned at 0 so "below the first threshold = base"
-- (old ns.ThresholdColor behaviour) is preserved exactly. Runs at login (MigrateProfile) and on
-- import (Share). Idempotent: clears cfg.thresholds, so a second pass no-ops.
function ns.MigrateThresholds(cfg)
    local th = cfg.thresholds
    if not th then return end
    cfg.thresholds = nil                 -- retire the legacy field either way
    if #th == 0 or cfg.colorCurve then return end   -- nothing to fold, or a curve already wins
    -- A max so counts map to a 0..1 fill: tracker max → discrete-power max → the largest stop count.
    local tr = ns.TrackerOf(cfg)
    local mx = (tr and type(tr.max) == "number" and tr.max)
        or (tr and tr.type == "power" and ns.PowerMax and ns.PowerMax(tr.power))
    if not mx or mx <= 0 then
        mx = 0
        for _, t in ipairs(th) do if t.count and t.count > mx then mx = t.count end end
    end
    if mx <= 0 then return end
    local pts = { { pct = 0, color = cfg.color or { r = 0.2, g = 0.6, b = 1, a = 1 } } }
    for _, t in ipairs(th) do
        if t.count then pts[#pts + 1] = { pct = math.min(1, t.count / mx), color = t.color, sound = t.sound } end
    end
    cfg.colorCurve = { type = "Step", points = pts }
end

-- ── Diagnostics for `/cust curve` ──────────────────────────────────────
-- Probes the real client: does the API exist, does a curve build, and what does
-- an evaluation actually return? Tells us the truth before we depend on it.
function CC.Probe()
    local p = ns.Print
    p("|cffffd100curve dbg|r available=" .. tostring(CC.Available()))
    p(("  C_CurveUtil=%s CreateColorCurve=%s UnitPowerPercent=%s CreateColor=%s"):format(
        type(C_CurveUtil), tostring(C_CurveUtil and type(C_CurveUtil.CreateColorCurve)),
        type(UnitPowerPercent), type(CreateColor)))

    -- Every C_CurveUtil function, so we can see the real SCALAR-curve constructor
    -- name (needed to render % text on a secret power bar via engine-side ×100).
    if type(C_CurveUtil) == "table" then
        local names = {}
        for k, v in pairs(C_CurveUtil) do if type(v) == "function" then names[#names + 1] = k end end
        table.sort(names)
        p("  C_CurveUtil fns: " .. table.concat(names, ", "))
    end

    -- Did our pct-curve (0->0, 1->100) build, and what does UnitPowerPercent give
    -- with it? Truthiness/type only — the value is secret and can't be printed or
    -- compared. got=true + type=number => works (a Color would mean the curve type
    -- was ignored; nil => no scalar-curve constructor exists under the tried names).
    local Mana = (Enum and Enum.PowerType and Enum.PowerType.Mana) or 0
    local pv = CC.PowerPercent100("player", Mana)
    local ty = "nil"; if pv then pcall(function() ty = type(pv) end) end
    p(("  PowerPercent100(Mana): got=%s type=%s secret=%s"):format(
        tostring(pv and true or false), ty, tostring((pv and ns.IsSecret(pv)) or false)))

    -- If UnitPowerPercent returns a colour for a scalar curve (type=table above),
    -- the curve's OWN evaluator is the fallback — list which method names exist.
    if C_CurveUtil and C_CurveUtil.CreateCurve then
        local okc, sc = pcall(C_CurveUtil.CreateCurve)
        if okc and sc then
            local m = {}
            for _, name in ipairs({ "Evaluate", "EvaluateAt", "GetValue", "GetValueAt", "Compute", "Sample" }) do
                if type(sc[name]) == "function" then m[#m + 1] = name end
            end
            p("  CreateCurve methods: " .. (m[1] and table.concat(m, ", ") or "(none of the guessed names)"))
        end
    end

    if not (C_CurveUtil and C_CurveUtil.CreateColorCurve and CreateColor) then
        p("  -> curve constructor missing; colour-by-fill will no-op."); return
    end
    local ok, cc = pcall(C_CurveUtil.CreateColorCurve)
    p(("  create ok=%s type=%s (SetType=%s AddPoint=%s)"):format(
        tostring(ok), type(cc), tostring(cc and type(cc.SetType)), tostring(cc and type(cc.AddPoint))))
    if not ok or not cc then return end
    if cc.SetType then pcall(cc.SetType, cc, "Linear") end
    if cc.AddPoint then
        pcall(cc.AddPoint, cc, 0, CreateColor(1, 0, 0, 1))
        pcall(cc.AddPoint, cc, 1, CreateColor(0, 1, 0, 1))
    end

    if not UnitPowerPercent then p("  UnitPowerPercent missing"); return end
    local eok, a = pcall(UnitPowerPercent, "player", Mana, false, cc)
    p(("  UnitPowerPercent(player,Mana) ok=%s ret=%s"):format(tostring(eok), type(a)))
    if eok and type(a) == "table" then
        -- The returned Color's RGB are SECRET (derived from the secret %), so we
        -- must NOT format them here — that errors. Confirm GetRGB resolves and
        -- whether the values are secret; the real path feeds them straight into
        -- SetStatusBarColor (which accepts secrets), so secret is expected + fine.
        local okGet, r = pcall(function() return a:GetRGB() end)
        local secret = okGet and ns.IsSecret(r)
        p(("    -> GetRGB ok=%s, RGB secret=%s (secret expected — setters accept it)"):format(
            tostring(okGet), tostring(secret)))
        if okGet and not secret and type(r) == "number" then
            p(("    -> readable sample R=%.2f"):format(r))
        end
    end
end
