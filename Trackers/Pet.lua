-- Trackers/Pet.lua : a PET / guardian that should be summoned — Hunter pet, Warlock demon,
-- Frost Mage Water Elemental. Drives a "missing pet" reminder via the standard icon path:
--   present = true   you have a live pet
--   present = false  no pet -> remind (summon it)
--   present = nil    HELD/silent: intentionally petless (Grimoire of Sacrifice / Lone Wolf)
--                    via cfg.petlessAura, or dead (can't summon on a corpse)
--
-- Config: { type = "pet", spellID = <the SUMMON spell — ICON only>,
--           petlessTalent = <talent spellID that LOCKS pets out>,
--           petlessAura   = <buff spellID that means "intentionally no pet"> }
--
-- Two ways a build is petless-by-design, both handled so the reminder never nags wrongly:
--   1. a talent that locks pets out — MM Hunter's Avian Specialization (the summon STAYS in
--      the spellbook, just locked, so we can't gate on "summon known"), Frost Mage's Lonely
--      Winter. Gated by cfg.petlessTalent (IsPlayerSpell — is that talent taken?).
--   2. an active "petless" buff — Warlock's Grimoire of Sacrifice keeps the summon known but
--      converts the pet into a buff. Gated by cfg.petlessAura.
--
-- Pet state is READABLE (UnitExists / UnitIsDead are not secret), so this works in and out
-- of combat — no oracle needed. A DEAD pet still "exists", so we treat dead as missing (it
-- needs resummoning / reviving).

local ADDON, ns = ...

local spellIcon = ns.SpellIcon

-- present=true have a live pet · false missing (remind) · nil silent (petless build / dead)
local snap = ns.PresenceSnap

-- Does the player have a DEAD pet needing Revive Pet (vs no pet at all → Call Pet)? HYSTERETIC:
-- UnitExists("pet") briefly flips FALSE mid-Revive-Pet-cast, and reads false for a dead-but-not-
-- in-slot pet (e.g. after a relog). Without a latch that flips the reminder to "no pet → Call
-- Pet" and — if you interrupt the revive — locks it there. So we latch "dead" on an exists+dead
-- read and only CLEAR it when a LIVE pet is actually seen (the revive / a summon succeeded).
-- Shared so the tracker icon and the click-to-cast (Widget:CastSpellName) agree.
local petWasDead = false
function ns.PetNeedsRevive()
    if UnitExists("pet") then
        petWasDead = (UnitIsDead and UnitIsDead("pet")) and true or false
    end   -- no pet unit: KEEP the latched state (transient during revive / dead-not-in-slot)
    return petWasDead
end

ns.RegisterTracker("pet", {
    -- UNIT_PET fires when your pet is summoned / dismissed / dies. The death trio gates the
    -- can't-summon-while-dead case; ENTERING_WORLD catches login / zone-in;
    -- MOUNT_DISPLAY_CHANGED re-reads when you mount / dismount (pets auto-dismiss on a mount).
    events = { "UNIT_PET", "PLAYER_ENTERING_WORLD", "PLAYER_DEAD", "PLAYER_ALIVE", "PLAYER_UNGHOST", "PLAYER_MOUNT_DISPLAY_CHANGED" },
    read = function(cfg)
        local icon = cfg.icon or spellIcon(cfg.spellID)

        -- Dead / ghost: you can't summon on a corpse -> hold silent.
        if ns.PlayerDead() then return snap(nil, icon) end

        -- Mounted (or on a taxi) auto-dismisses your pet — it re-summons the moment you land /
        -- dismount. Don't nag about a "missing" pet in the air; hold silent until you're on foot.
        if (IsMounted and IsMounted()) or (UnitOnTaxi and UnitOnTaxi("player")) then return snap(nil, icon) end

        local needsRevive = ns.PetNeedsRevive and ns.PetNeedsRevive()   -- also refreshes the latch

        -- A live pet in the pet slot -> have it.
        if UnitExists("pet") and not (UnitIsDead and UnitIsDead("pet")) then
            return snap(true, icon)
        end

        -- A DEAD pet (active-dead, mid-revive, or dead-not-in-slot) -> flag it with the REVIVE
        -- icon, distinct from "no pet". Shown even IN COMBAT (pet state isn't secret) and click-
        -- to-cast resolves to Revive Pet. The latch keeps this from flickering to Call Pet during
        -- the revive cast. Only pet builds ever have a dead pet, so it can't fire on a petless one.
        if cfg.reviveWhenDead and needsRevive then
            return snap(false, spellIcon(cfg.reviveWhenDead) or icon)
        end

        -- No live pet — but is this build petless BY DESIGN? Then it's not "missing", stay silent:
        --   · a talent locks pets out (MM Avian Spec, Frost Lonely Winter) — the summon stays in
        --     the spellbook, so check the TALENT (strict ns.SpellTaken — fail-closed, not the
        --     fail-open ns.SpellKnown, so we only silence when it's definitely taken).
        --   · an active buff converts the pet away (Warlock Grimoire of Sacrifice).
        if cfg.petlessTalent and ns.SpellTaken(cfg.petlessTalent) then return snap(nil, icon) end
        if cfg.petlessAura and ns.PlayerAura(cfg.petlessAura) then return snap(nil, icon) end

        -- Genuinely missing -> remind.
        return snap(false, icon)
    end,
})

-- UNIT_PET (the tracker's own event) does NOT reliably fire on pet DEATH — only on summon /
-- dismiss. So watch the pet's HEALTH (RegisterUnitEvent scopes it to the pet unit, so it only
-- fires for the pet, not every unit) and react to the alive<->dead transition: re-read the
-- tracker (so the reminder + Revive icon update even IN combat — pet state isn't secret) and
-- re-point pet reminders' click-to-cast (Call Pet <-> Revive Pet). RefreshCast defers in combat
-- and re-applies on PLAYER_REGEN_ENABLED, so the Revive cast is ready the moment you're out.
local petWatch = CreateFrame("Frame")
petWatch:RegisterUnitEvent("UNIT_HEALTH", "pet")
local lastDead = false
petWatch:SetScript("OnEvent", function()
    local dead = (UnitExists("pet") and UnitIsDead and UnitIsDead("pet")) and true or false
    if dead == lastDead then return end   -- an ordinary health tick, not an alive<->dead change
    lastDead = dead
    ns.Refresh()
    if ns.widgets and ns.profile and ns.profile.trackers then
        for _, w in pairs(ns.widgets) do
            local tr = ns.TrackerOf(w.cfg)
            if tr and tr.type == "pet" and w.RefreshCast then w:RefreshCast() end
        end
    end
end)

-- ── /cust pet : probe pet state (run on Hunter / Warlock / Mage to verify) ──
-- Prints the raw reads the tracker uses, so we can confirm each class registers its pet in
-- the "pet" slot, and find the petless-buff id for Grimoire of Sacrifice / Lone Wolf builds.
-- Per class: the summon (icon) + candidate petless signals, so the probe can show which one
-- actually distinguishes a petless build from a pet build on the SAME character.
local SUMMON  = { HUNTER = 883, WARLOCK = 688, MAGE = 31687 }   -- Call Pet / Summon Imp / Water Elemental
local PETLESS = {
    HUNTER  = { talent = 466867, label = "Avian Specialization" },
    WARLOCK = { talent = 108503, label = "Grimoire of Sacrifice" },
    MAGE    = { talent = 205024, label = "Lonely Winter" },
}
function ns.PetProbe()
    local exists = UnitExists("pet")
    local name   = exists and UnitName("pet") or nil
    local dead   = exists and UnitIsDead and UnitIsDead("pet")
    ns.Print(("|cffffd100pet|r exists=%s name=%s dead=%s"):format(tostring(exists), tostring(name), tostring(dead)))

    local sid = SUMMON[ns.playerClass]
    if sid then
        local known  = ns.SpellTaken(sid)
        local usable = ns.SpellUsable and ns.SpellUsable(sid)   -- does a LOCKED summon read unusable?
        ns.Print(("  summon %d: known=%s usable=%s |cff808080(known stays true when locked; usable=false would be a clean universal gate)|r"):format(
            sid, tostring(known), tostring(usable)))
    end
    local pl = PETLESS[ns.playerClass]
    if pl then
        local taken = ns.SpellTaken(pl.talent)
        ns.Print(("  petless talent %s (%d): taken=%s |cff808080(taken=true -> reminder stays silent)|r"):format(pl.label, pl.talent, tostring(taken)))
    end
    ns.Print("  Warlock petless (Grimoire of Sacrifice) keeps the summon known — run |cffffd100/cust aura Grimoire of Sacrifice|r OOC for its petlessAura id.")
end

-- Name of the beast in Hunter Call Pet slot 1-5 (slot index == GetStablePetInfo index,
-- confirmed live), so the summon picker can read "Call Pet 1 — FeroBoy" instead of five
-- identical rows. Returns nil for an empty slot or before the stable API has data — the
-- caller falls back to the plain slot name. Never errors (pcall around the API).
function ns.CallPetName(slot)
    if not (C_StableInfo and C_StableInfo.GetStablePetInfo) then return nil end
    local ok, info = pcall(C_StableInfo.GetStablePetInfo, slot)
    if ok and type(info) == "table" and info.name and info.name ~= "" then return info.name end
    return nil
end

-- ── /cust pets : map Hunter Call Pet slots 1-5 to the beast in each ──
-- The summon picker wants to show "Call Pet 1 — Bloodfang" instead of five identical rows,
-- but the slot->name mapping has to be confirmed live: the stable API only populates once the
-- stable's been loaded, and the index<->Call-Pet-slot correspondence needs verifying. This
-- dumps whatever the API returns so we can wire the picker labels correctly.
function ns.CallPetProbe()
    ns.Print("|cffffd100Call Pet slots|r (Hunter):")
    if UnitExists("pet") then
        ns.Print(("  currently summoned: |cff40ff40%s|r"):format(UnitName("pet") or "?"))
    end
    if not C_StableInfo then
        ns.Print("  |cffff6060C_StableInfo is nil|r — the stable API isn't available; try after opening a Stable Master once.")
        return
    end
    local nActive = C_StableInfo.GetNumActivePets and C_StableInfo.GetNumActivePets()
    ns.Print(("  GetNumActivePets = %s"):format(tostring(nActive)))
    if C_StableInfo.GetStablePetInfo then
        for i = 1, 5 do
            local ok, info = pcall(C_StableInfo.GetStablePetInfo, i)
            if ok and type(info) == "table" then
                ns.Print(("  [%d] name=%s species=%s slot=%s"):format(
                    i, tostring(info.name), tostring(info.speciesName), tostring(info.slotID or info.petNumber)))
            else
                ns.Print(("  [%d] %s"):format(i, ok and "nil" or "error reading"))
            end
        end
    else
        ns.Print("  |cffff6060C_StableInfo.GetStablePetInfo is nil|r.")
    end
end
