-- Trackers/DemonHunter.lua : Demon Hunter secondary resources that no plain UnitPower gives us.
--
-- Two trackers, both fed to the bar SECRET-safe (the counts are secret in combat — never compared
-- or mathed here, handed straight to SetValue). Spell ids + read methods sourced from Sensei-
-- ClassResourceBar (facts, not its code):
--
--   soulfrag_veng — Vengeance's Soul Fragments (0-6). No aura/power exposes the count, but
--     C_Spell.GetSpellCastCount(Soul Cleave 228477) returns how many you hold. Fragments change
--     with no dedicated event, so a light ticker re-reads while you're Vengeance (like Stagger).
--
--   voidmeta — Devourer's Soul Fragment POOL (0-35/50) that fuels Void Metamorphosis. It's the
--     stack count of the Soul Fragments aura (1225789) or Collapsing Star (1227702); the ceiling
--     is 35 with the Soul Glutton talent (1247534) else 50. UNIT_AURA covers every change.

local ADDON, ns = ...

local spellIcon = ns.SpellIcon

-- ── Vengeance Soul Fragments (0-6) ────────────────────────────────────────
local SOUL_CLEAVE = 228477   -- GetSpellCastCount on this = fragments held
local VENG_MAX    = 6

local function vengFrags()
    local n = C_Spell and C_Spell.GetSpellCastCount and C_Spell.GetSpellCastCount(SOUL_CLEAVE)
    return n or 0
end

ns.RegisterTracker("soulfrag_veng", {
    -- No event fires per fragment, so lean on the ticker below; these just catch the obvious edges.
    events = { "UNIT_AURA", "SPELL_UPDATE_USABLE", "SPELL_UPDATE_CHARGES", "UNIT_POWER_FREQUENT",
               "PLAYER_ENTERING_WORLD", "PLAYER_REGEN_ENABLED", "PLAYER_REGEN_DISABLED" },
    unitEvent = true,
    read = function(cfg)
        local n = vengFrags()
        return { value = n, max = VENG_MAX, count = n, icon = spellIcon(SOUL_CLEAVE) }
    end,
})

-- Fragments spawn/despawn with no per-change event, so re-read on a light ticker while you're a
-- Vengeance DH (one cheap API call ~6×/sec, only for that spec). Mirrors the Stagger ticker.
-- The ticker frame is only created on a Demon Hunter — on every other class this file still
-- registers its trackers (harmless, never read) but no permanent OnUpdate runs.
if ns.playerClass == "DEMONHUNTER" then
    local ticker = CreateFrame("Frame"); ticker:Hide()
    local acc = 0
    ticker:SetScript("OnUpdate", function(_, dt)
        acc = acc + dt
        if acc < 0.15 then return end
        acc = 0
        if ns.Trackers then ns.Trackers.RefreshType("soulfrag_veng") end   -- re-read just the fragments bar
    end)
    -- Only run the poll on Vengeance (581); a hidden frame's OnUpdate doesn't fire (was: an in-loop
    -- specID check every frame). ns.OnSpecChange fires once at build and on every spec change.
    if ns.OnSpecChange then ns.OnSpecChange(function() ticker:SetShown(ns.specID == 581) end) end
end

-- ── Devourer Void Metamorphosis pool (0-35/50) ────────────────────────────
local SF_AURA, SF_AURA2 = 1225789, 1227702   -- Soul Fragments / Collapsing Star (either carries the stacks)
local SOUL_GLUTTON      = 1247534            -- talent that lowers the ceiling to 35
local VOID_META         = 1217607            -- the Void Metamorphosis buff (icon + the active state)

-- Our own two-tone: the pool is the base purple (set on the widget); while Void Metamorphosis is
-- ACTUALLY up, the bar lights to this brighter purple so the empowered window reads at a glance.
local VOID_ACTIVE_COLOR = { r = 0.80, g = 0.35, b = 1.00, a = 1 }

local function voidMax()
    local known = C_SpellBook and C_SpellBook.IsSpellKnown and C_SpellBook.IsSpellKnown(SOUL_GLUTTON)
    return known and 35 or 50
end

ns.RegisterTracker("voidmeta", {
    events = { "UNIT_AURA", "PLAYER_ENTERING_WORLD", "PLAYER_REGEN_ENABLED" },
    unitEvent = true,
    read = function(cfg)
        -- ns.PlayerAura guarantees a plain table or nil, so these `a and …` tests can never meet
        -- a secret struct (see the wrapper's note in Core/Spells.lua). `applications` itself stays
        -- untouched — it's the secret stack count and is handed straight to the bar's setter.
        local a = ns.PlayerAura(SF_AURA) or ns.PlayerAura(SF_AURA2)
        local v = (a and a.applications) or 0
        local ic = (a and a.icon) or spellIcon(VOID_META) or spellIcon(SF_AURA)
        -- Void Metamorphosis active? Aura PRESENCE (nil vs table) is readable even in combat — a
        -- plain existence check, no math on secret fields. Drives the bar's live state colour.
        local voidActive = ns.PlayerAura(VOID_META) ~= nil
        return { value = v, max = voidMax(), count = v, icon = ic,
                 fillColor = voidActive and VOID_ACTIVE_COLOR or nil }
    end,
})

-- ── Widgets ───────────────────────────────────────────────────────────────
-- Vengeance Soul Fragments: a 6-box segmented bar (one box per fragment), DH purple.
function ns.AddSoulFragVengWidget()
    return ns.SpawnWidget({ type = "soulfrag_veng", max = VENG_MAX }, {   -- max on the tracker → 6 boxes
        name       = "Soul Fragments",
        segments   = true,
        showText   = true,
        textFormat = "value",
        color      = { r = 0.64, g = 0.19, b = 0.79, a = 1 },   -- Demon Hunter purple
        width      = 200, height = 22,
    }, { specs = { [581] = true } })   -- Vengeance only
end

-- Devourer Void Metamorphosis: a continuous bar of the Soul Fragment pool (0-35/50), Void purple.
function ns.AddVoidMetaWidget()
    return ns.SpawnWidget({ type = "voidmeta" }, {
        name       = "Void Metamorphosis",
        showText   = true,
        textFormat = "valuemax",
        color      = { r = 0.278, g = 0.125, b = 0.796, a = 1 },   -- Void purple (Sensei)
        width      = 220, height = 22,
        fullGlow   = true,   -- glow at cap (35/50) — the pool reads live in combat, so this fires mid-fight
        fullGlowColor = { r = 0.80, g = 0.35, b = 1.00, a = 1 },   -- bright Void purple
    }, { specs = { [1480] = true } })   -- Devourer only
end

-- ── /cust voidmeta : hunt a combat-READABLE "pool full / ready" signal ──────
-- The pool count (Soul Fragments aura `applications`) is SECRET in combat, so `count >= cap`
-- can't drive a "bar full" effect there. This probe dumps every candidate that MIGHT stay
-- readable, so we can see which one flips exactly at cap AND survives combat. Run it four times
-- and paste all four: (1) low pool OOC, (2) AT cap OOC, (3) AT cap in combat, (4) mid-pool in
-- combat. Optionally pass the Void Metamorphosis ABILITY id from your spellbook to test its
-- usability: /cust voidmeta <spellID>  (IsSpellUsable is readable in combat — if Void Meta only
-- becomes castable at cap, that's our signal).
function ns.VoidMetaProbe(arg)
    local sv = function(v) if ns.IsSecret(v) then return "|cffff4040<secret>|r" end local ok, s = pcall(tostring, v); return ok and s or "?" end
    ns.Print(("|cffffd100voidmeta|r combat=%s aurasSecret=%s cap=%s"):format(
        tostring(InCombatLockdown()), tostring(ns.AurasSecretNow and ns.AurasSecretNow()), tostring(voidMax())))

    -- The pool itself — is the stack count readable right now, and what is it?
    local a = ns.PlayerAura(SF_AURA) or ns.PlayerAura(SF_AURA2)
    ns.Print(("  pool aura: %s  stacks=%s  dur=%s"):format(a and "|cff40ff40FOUND|r" or "|cffff4040nil|r",
        a and sv(a.applications) or "-", a and sv(a.duration) or "-"))

    -- Void Metamorphosis buff presence (readable) — the ACTIVE window, not "ready".
    ns.Print(("  Void Meta buff (%d) present=%s"):format(VOID_META, tostring(ns.PlayerAura(VOID_META) ~= nil)))

    -- IsSpellUsable booleans are AllowedWhenTainted (readable in combat). If Void Meta only casts
    -- at cap, usable=true is our "full" signal. Test the buff id + any id you pass in.
    local ids = { VOID_META }
    local extra = tonumber(arg)
    if extra then ids[#ids + 1] = extra end
    for _, id in ipairs(ids) do
        local usable, noRes
        if ns.SpellUsable then usable, noRes = ns.SpellUsable(id) end
        local nm = (C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(id)) or "?"
        ns.Print(("  IsSpellUsable(%s |cff9fd6ff%s|r) = usable=%s insufficientPower=%s"):format(
            tostring(id), tostring(nm), tostring(usable), tostring(noRes)))
    end

    -- Full aura dump: a "pool capped" indicator often appears as its OWN buff. List every HELPFUL
    -- aura (id + name + stacks), so a cap-marker aura we don't know about surfaces here.
    if AuraUtil and AuraUtil.ForEachAura then
        ns.Print("  HELPFUL auras (look for a 'capped'/'max' buff that appears only at full):")
        local n = 0
        pcall(AuraUtil.ForEachAura, "player", "HELPFUL", nil, function(au)
            if not au then return end
            n = n + 1
            ns.Print(("    %s |cff808080#%s|r stacks=%s"):format(sv(au.name), sv(au.spellId), sv(au.applications)))
        end, true)
        if n == 0 then ns.Print("    (none readable)") end
    end
end
ns.RegisterSlash("voidmeta", ns.SlashProbe("VoidMetaProbe", "voidmeta probe"))
