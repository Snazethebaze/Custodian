-- Trackers/Shatter.lua : Frost Mage "shatter" — the frozen/Winter's-Chill TARGET debuff.
--
-- A target debuff is SECRET in combat, so we can't read it with AuraUtil/GetAuraDataBySpellID.
-- Blizzard's Cooldown Manager viewers CAN show it (they're whitelisted), so — like SenseiClass-
-- ResourceBar's Freeze helper — we piggyback: find the CDM item frame whose aura is our spell on
-- the "target" unit, grab its auraInstanceID, and read stacks via GetAuraDataByAuraInstanceID.
--
-- STATUS: probe first. /cust shatter dumps what the CDM is actually tracking (spell id + name +
-- unit + stacks) so we can (a) confirm what 1246769 is and (b) confirm the target debuff is even
-- in the CDM before building the tracker on top of it.

local ADDON, ns = ...

local spellIcon = ns.SpellIcon

local function isSecret(v)
    if ns.IsSecret then return ns.IsSecret(v) end
    return _G.issecretvalue and _G.issecretvalue(v)
end

-- Every CDM viewer's item frames, across the buff/debuff + essential/utility viewers.
local VIEWERS = {
    "BuffIconCooldownViewer", "BuffBarCooldownViewer",
    "EssentialCooldownViewer", "UtilityCooldownViewer",
}

local SHATTER     = 1246769   -- "Shatter" (confirmed via /cust shatter)
local SHATTER_MAX = 20        -- ceiling per SenseiClassResourceBar's Freeze helper (VERIFY)

-- Is this CDM item the Shatter debuff on the target? (cooldownID -> spellID, re-checked at read
-- time since the CDM re-pools item frames onto different spells.)
local function isShatterFrame(f)
    if f.auraDataUnit ~= "target" then return false end
    local cdID = f.cooldownID
    local info = cdID and C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo
        and C_CooldownViewer.GetCooldownViewerCooldownInfo(cdID)
    return info and info.spellID == SHATTER
end

-- Optional: hide the game's own Shatter icon in the CDM (so it isn't shown twice — the CDM icon
-- AND our widget). Driven by any shatter tracker with cfg.hideCdmIcon. We only ever SetAlpha the
-- item frame (a passive write — taint-safe, per the CDMBars rules) and re-apply it from the frame
-- hooks below, so the CDM can't quietly un-hide it. Self-heals: flip the option off and the next
-- CDM update on the Shatter frame restores alpha 1.
local function wantHide()
    local trs = ns.profile and ns.profile.trackers
    if trs then
        for _, c in pairs(trs) do if c.type == "shatter" and c.hideCdmIcon then return true end end
    end
    return false
end
local function applyAlpha(f)
    if f then pcall(f.SetAlpha, f, wantHide() and 0 or 1) end
end

-- Read Shatter off the CDM: present (a readable bool — the item being shown) + its stack count
-- (usually a SECRET number in combat, fed straight to the bar via SetValue — never compared here).
local function readShatter()
    for _, vn in ipairs(VIEWERS) do
        local v = _G[vn]
        if v and v.GetItemFrames then
            local ok, items = pcall(v.GetItemFrames, v)
            if ok and type(items) == "table" then
                for _, f in ipairs(items) do
                    if f:IsShown() and isShatterFrame(f) then
                        applyAlpha(f)   -- honour the hide-the-CDM-icon option
                        local aid = f.auraInstanceID
                        if aid and C_UnitAuras and C_UnitAuras.GetAuraDataByAuraInstanceID then
                            local ok2, d = pcall(C_UnitAuras.GetAuraDataByAuraInstanceID, "target", aid)
                            if ok2 and type(d) == "table" and d.applications ~= nil then
                                return true, d.applications   -- present, stacks (maybe secret)
                            end
                        end
                        return true, 1   -- present but stacks unreadable → at least one
                    end
                end
            end
        end
    end
    return false, 0
end

-- Hook the CDM item frames ONCE so a Shatter change refreshes our widget in lockstep with the CDM
-- (UNIT_AURA on the target also covers it; this just avoids a one-event lag). Only the Shatter
-- frame triggers a refresh, so it isn't a per-aura firehose.
local hooked = setmetatable({}, { __mode = "k" })
local function ensureHooks()
    for _, vn in ipairs(VIEWERS) do
        local v = _G[vn]
        if v and v.GetItemFrames then
            local ok, items = pcall(v.GetItemFrames, v)
            if ok and type(items) == "table" then
                for _, f in ipairs(items) do
                    if not hooked[f] then
                        hooked[f] = true
                        for _, m in ipairs({ "SetAuraInstanceInfo", "ClearAuraInstanceInfo", "OnUnitAuraUpdatedEvent" }) do
                            if type(f[m]) == "function" then
                                -- pcall: 12.1's Forbidden Aspects could make hooking a CDM item throw.
                                pcall(hooksecurefunc, f, m, function(fr)
                                    if isShatterFrame(fr) then
                                        applyAlpha(fr)   -- keep the hide sticky (CDM re-shows it)
                                        ns.Refresh()
                                    end
                                end)
                            end
                        end
                    end
                end
            end
        end
    end
end

ns.RegisterTracker("shatter", {
    -- unit = "target" so the engine passes UNIT_AURA aimed at the target; the CDM hooks keep it
    -- in lockstep. TARGET_CHANGED re-reads on a swap; ENTERING_WORLD primes on login.
    events = { "UNIT_AURA", "PLAYER_TARGET_CHANGED", "PLAYER_ENTERING_WORLD" },
    unitEvent = true,
    read = function(cfg)
        ensureHooks()
        local present, stacks = readShatter()
        return { active = present, present = present, count = present and stacks or 0,
                 value = present and stacks or 0, max = SHATTER_MAX,
                 icon = spellIcon(SHATTER), noCount = true }
    end,
})

-- Create a Shatter widget (Frost Mage): a bar of the target's Shatter stacks (secret-safe fill),
-- Frost-spec only. Reads via the Cooldown Manager, so the Shatter debuff must be tracked there.
function ns.AddShatterWidget()
    return ns.SpawnWidget({ type = "shatter", unit = "target" }, {
        name       = "Shatter",
        showText   = true,
        textFormat = "value",
        color      = { r = 0.35, g = 0.70, b = 1.00, a = 1 },   -- frost blue
        width      = 200, height = 22,
    }, { specs = { [64] = true } })   -- Frost spec only
end

-- ── /cust shatter : what target auras is the Cooldown Manager tracking? ──
-- Run it IN COMBAT with a frozen target. For each CDM item we print the spell it maps to and,
-- when it's a "target" aura we can resolve, its stack count (SECRET flagged). This tells us the
-- real shatter/freeze spell id and whether the CDM path can read it.
function ns.ShatterProbe()
    ns.Print(("|cffffd100shatter / CDM debuff probe|r  combat=%s  target=%s"):format(
        tostring(InCombatLockdown()), tostring(UnitExists("target") and UnitName("target") or "none")))
    local anyTarget = false
    for _, vn in ipairs(VIEWERS) do
        local v = _G[vn]
        if v and v.GetItemFrames then
            local ok, items = pcall(v.GetItemFrames, v)
            if ok and type(items) == "table" then
                for _, f in ipairs(items) do
                    local cdID = f.cooldownID
                    local info = cdID and C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo
                        and C_CooldownViewer.GetCooldownViewerCooldownInfo(cdID)
                    local sid  = info and info.spellID
                    local unit = f.auraDataUnit
                    local aid  = f.auraInstanceID
                    -- Focus on TARGET auras (the shatter/freeze debuff); print those loudly.
                    if unit == "target" then
                        anyTarget = true
                        local nm = sid and C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(sid)
                        local apps = "?"
                        if aid and not isSecret(aid) and C_UnitAuras and C_UnitAuras.GetAuraDataByAuraInstanceID then
                            local ok2, d = pcall(C_UnitAuras.GetAuraDataByAuraInstanceID, "target", aid)
                            if ok2 and type(d) == "table" then
                                apps = isSecret(d.applications) and "SECRET" or tostring(d.applications)
                            else apps = "read-failed" end
                        elseif aid then apps = "instID-secret" end
                        ns.Print(("  |cff40ff40[target]|r %s spell=%s (%s) shown=%s stacks=%s"):format(
                            vn, tostring(sid), tostring(nm), tostring(f:IsShown()), apps))
                    end
                end
            end
        end
    end
    if not anyTarget then
        ns.Print("  |cffff6060no 'target' auras in any CDM viewer.|r Add the freeze/Winter's Chill")
        ns.Print("  debuff to your Cooldown Manager (Edit Mode → Cooldown Manager → tracked auras),")
        ns.Print("  freeze the target, and re-run. If it never appears, the CDM can't feed it to us.")
    end
end
