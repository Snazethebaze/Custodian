-- Trackers/WeaponImbue.lua : a temporary WEAPON ENCHANT (imbue) — Windfury /
-- Flametongue Weapon, sharpening stones, poisons, any main/off-hand imbue.
--
-- These are NOT auras. GetPlayerAuraBySpellID / AuraUtil.ForEachAura never
-- enumerate them, which is exactly why an aura tracker can't find Windfury —
-- weapon enchants live in their own system, read via GetWeaponEnchantInfo().
--
-- Config: { type = "imbue", slot = "main" | "off" | "either",
--           spellID = <optional; only for the icon + label>,
--           riteIds = { <spellID>, … }  -- choice-node imbue (Lightsmith Rites): gate + icon + cast
--             resolve LIVE by id (IsPlayerSpell) — shows/casts whichever rite you actually took.
--           talentGate = { mode = "require"|"suppress", spell = <spellID> | spells = { <spellID>, … } }
--             "require"  — only EXPECT this imbue when that talent/spell is known (Elemental's
--                          Flametongue Weapon); held/silent otherwise.
--             "suppress" — do NOT expect it when that talent is known (a weapon oil is pointless
--                          once you're running Flametongue) — held/silent when taken.
-- The pair keeps two mutually-exclusive main-hand reminders (Flametongue vs oil) from doubling up:
-- exactly one is ever active for a given talent state. }
--
-- SIMPLE MODEL (2026-07-14) — mirrors Trackers/Aura.lua. Weapon enchants read LIVE
-- in combat (has-flag + msLeft both readable, not secret-wrapped), so we treat an
-- imbue like a "live" aura and TRUST the read: found -> present, not-found -> missing
-- (dead -> held/silent). Deleted the old per-slot `lastOOC` hold, the combat
-- special-casing, and the UNIT_SPELLCAST_SUCCEEDED reapply-watch — they existed only
-- to mask a RARE, unexplained intermittent "hidden-as-false" in-combat read (caught
-- once on main-hand Windfury). Trusting the read means that flicker can briefly show a
-- false "missing" nag, but it self-corrects on the next read (and PLAYER_REGEN_ENABLED
-- re-reads at combat end) — the same trade the aura live-branch accepts. ns.IsSecret is
-- still checked first everywhere, in case a future build wraps these as real secrets.

local ADDON, ns = ...

local GetWeaponEnchantInfo = GetWeaponEnchantInfo
local GetTime = GetTime

-- Shared spell metadata helpers (defined in Core/Spells.lua, loaded first).
-- Icon is optional — a slot-only tracker has no spellID and the icon widget
-- falls back to a "?".
local spellIcon = ns.SpellIcon

-- An ITEM's icon (a weapon oil, an augment rune…), when the reminder is set to a specific item.
local itemIcon = ns.ItemIcon

-- The equipped WEAPON's own icon for this slot — the FALLBACK art for a generic "empty" imbue
-- reminder (no chosen spell / item), so it doesn't show a bare question mark. Player equipment
-- is readable; re-read on PLAYER_EQUIPMENT_CHANGED keeps it current on weapon swaps.
local function weaponIcon(slot)
    if not GetInventoryItemTexture then return nil end
    local tex = GetInventoryItemTexture("player", (slot == "off") and 17 or 16)
    if not tex and slot == "either" then tex = GetInventoryItemTexture("player", 17) end
    if tex and not ns.IsSecret(tex) then return tex end
    return nil
end

-- Last readable remaining-ms per slot, so a HELD read (dead/unreadable) keeps the icon
-- looking the same (lit + countdown) instead of flashing blank — same as the aura
-- tracker's lastAura cache.
local lastMs = {}

-- ── The three snapshots, so read() stays flat (mirrors Aura.lua) ──────────
-- present=true  -> you have it (icon lit + countdown)
-- present=false -> genuinely missing (a "missing" reminder shows)
-- present=nil   -> HELD: unreadable or dead (icon stays lit off lastMs; reminder hidden)

-- A CHOICE-NODE imbue (Lightsmith's two Rites) shares the weapon slot and GetWeaponEnchantInfo
-- can't tell them apart. We gate on knowing EITHER Rite by SPELL ID (a direct IsPlayerSpell query
-- — NAME/spellbook lookup fails, these hero-talent abilities aren't enumerated there) and show
-- whichever you took. cfg.riteIds = { 433568 Sanctification, 433583 Adjuration }. Returns
-- known(bool / nil if no rite set), and the id+icon of the rite you have.
local function knownRite(cfg)
    local ids = cfg.riteIds
    if not ids then return nil end
    for _, id in ipairs(ids) do
        if ns.SpellTaken(id) then return true, id, spellIcon(id) end
    end
    return false
end

-- Talent gate — see the config note. `require` hides the reminder unless the talent is known;
-- `suppress` hides it when the talent IS known. `g.spell` is a single talent id; `g.spells` an
-- ANY-OF id set. cfg.riteIds drives the id-based choice-node gate above (takes precedence).
local function gateKnown(g)
    if g.spells then
        for _, id in ipairs(g.spells) do if ns.SpellTaken(id) then return true end end
        return false
    end
    if g.spell then return ns.SpellTaken(g.spell) end
    return nil
end
local function gateHeld(cfg)
    local g = cfg.talentGate
    if not g then return false end
    local known
    if cfg.riteIds then known = knownRite(cfg)   -- choice-node rite: match by spell id, live
    else known = gateKnown(g) end
    if known == nil then return false end           -- can't tell → don't suppress (no false silence)
    if g.mode == "require"  then return not known end
    if g.mode == "suppress" then return known and true or false end
    return false
end

-- The icon of whichever Rite you actually took (choice-node imbue), for the widget art.
local function knownRiteIcon(cfg)
    local ok, _, icon = knownRite(cfg)
    if ok then return icon end
    return nil
end

local function present(icon, ms)
    -- ms is REMAINING (not an absolute stamp). IsSecret FIRST so a secret ms never
    -- reaches the ~= nil / > 0 compares (future-proofing — today these read plain).
    -- The sweep's `duration` is the imbue's TOTAL, which the API doesn't give — so we
    -- assume the standard ~1h (weapon imbues are 60 min) so the icon sweep drains toward
    -- empty as it expires (using `rem` as duration would reset the clock to full on every
    -- re-read — the opposite of a low-time cue). Expiration is exact regardless.
    local expiration, duration
    if not ns.IsSecret(ms) and ms ~= nil and ms > 0 then
        local rem = ms / 1000
        expiration = GetTime() + rem
        duration   = (rem > 3600) and rem or 3600
    end
    return { active = true, present = true, count = 0, value = 1, max = 1,
             icon = icon, duration = duration, expiration = expiration, noCount = true }
end

local function missing(icon)
    return { active = false, present = false, count = 0, value = 0, max = 1, icon = icon, noCount = true }
end

local function held(icon, slot)
    -- present=nil: keep the icon lit with the last-known timer; a "missing" reminder
    -- stays HIDDEN (can't fault you for a buff you can't read, or re-imbue while dead).
    local ms = lastMs[slot]
    local expiration, duration
    if ms and not ns.IsSecret(ms) and ms > 0 then
        local rem = ms / 1000
        expiration = GetTime() + rem
        duration   = (rem > 3600) and rem or 3600
    end
    return { active = true, present = nil, count = 0, value = 0, max = 1,
             icon = icon, duration = duration, expiration = expiration, noCount = true }
end

-- ── /cust imbuegate : why aren't the Flametongue / oil reminders mutually exclusive? ──
-- Prints each imbue tracker's talent-gate fields (requireTalent / suppressIfTalent), whether an
-- itemID is set, and IsPlayerSpell for the candidate Flametongue Weapon ids — so we can see if a
-- gate is simply MISSING on a widget, or if the gate spell id doesn't reflect the talent.
local function ipsStr(id)
    if not id then return "nil" end
    local known = ns.SpellTaken(id)   -- what the gate actually uses (C_SpellBook → IsPlayerSpell)
    return ("%d(%s):|cff%sSpellTaken=%s|r"):format(id,
        tostring(C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(id)),
        known and "40ff40" or "ff4040", tostring(known))
end

function ns.ImbueGateProbe()
    ns.Print("|cffffd100imbue gate probe|r")
    -- Lightsmith rite ids (Sanctification 433568 / Adjuration 433583): the one you took should read
    -- IsPlayerSpell=true. IsSpellKnown shown too in case IsPlayerSpell doesn't flip for these.
    ns.Print("  Lightsmith rite ids (the one you took should be TRUE):")
    for _, id in ipairs({ 433568, 433583 }) do
        ns.Print(("    %s  IsSpellKnown=%s"):format(ipsStr(id),
            tostring(IsSpellKnown and IsSpellKnown(id))))
    end
    ns.Print("  Flametongue known-checks (FALSE when NOT specced): " .. ipsStr(318038))
    local trs = ns.profile and ns.profile.trackers
    local any = false
    if trs then
        for tid, cfg in pairs(trs) do
            if cfg.type == "imbue" then
                any = true
                local g = cfg.talentGate
                local gateStr = "none"
                if g then
                    if g.spells then
                        local parts = {}
                        for _, id in ipairs(g.spells) do parts[#parts + 1] = ipsStr(id) end
                        gateStr = g.mode .. " ANY-OF { " .. table.concat(parts, " , ") .. " }"
                    else
                        gateStr = g.mode .. ":" .. ipsStr(g.spell)
                    end
                end
                local riteStr = "nil"
                if cfg.riteIds then
                    local ok, id = knownRite(cfg)
                    riteStr = ("{%d} known=%s"):format(#cfg.riteIds, ok and ipsStr(id) or "|cffff4040none|r")
                end
                ns.Print(("  |cff9fd6ff[%s]|r slot=%s spellID=%s riteIds=%s"):format(
                    tid, tostring(cfg.slot), tostring(cfg.spellID), riteStr))
                ns.Print(("      gate=%s"):format(gateStr))
            end
        end
    end
    if not any then ns.Print("  (no imbue trackers in your profile)") end
    ns.Print("  A Rite widget should show |cff40ff40riteIds={…} known=…|r for the rite you took. If it")
    ns.Print("  reads |cffff4040riteIds=nil|r it predates the fix — delete and re-add it from the wizard.")
end

ns.RegisterTracker("imbue", {
    -- Applying / removing an imbue (and weapon swaps) fires UNIT_INVENTORY_CHANGED +
    -- PLAYER_EQUIPMENT_CHANGED. PLAYER_REGEN_ENABLED re-reads at combat end to clear any
    -- rare in-combat hidden-false flicker. The death trio drives the held-while-dead gate.
    -- ENTERING_WORLD catches a fresh login / zone-in.
    events = { "UNIT_INVENTORY_CHANGED", "PLAYER_EQUIPMENT_CHANGED", "PLAYER_REGEN_ENABLED",
               "PLAYER_ENTERING_WORLD", "PLAYER_DEAD", "PLAYER_ALIVE", "PLAYER_UNGHOST" },
    read = function(cfg)
        local slot = cfg.slot or "main"
        -- Icon priority: the chosen ITEM (oil / rune) → the KNOWN Rite (choice-node imbue) → the
        -- named imbue's SPELL art (Windfury, Flametongue) → the equipped weapon (generic "empty").
        local staticIcon = itemIcon(cfg.itemID) or knownRiteIcon(cfg) or spellIcon(cfg.spellID) or weaponIcon(slot)
        -- Talent gate (mutually-exclusive main-hand reminders — see the config note). Held =
        -- silent, so a "missing" reminder simply doesn't fire when this imbue doesn't apply.
        if gateHeld(cfg) then return held(staticIcon, slot) end
        if not GetWeaponEnchantInfo then return held(staticIcon, slot) end

        local mhHas, mhMs, _mhCh, _mhId, ohHas, ohMs = GetWeaponEnchantInfo()

        -- Resolve this tracker's hand(s) into a single has-flag + the countdown ms.
        -- Secret-guard the flags FIRST (plain today; future-proof) — a secret read means
        -- "can't tell" -> held. "either" is up if EITHER hand carries an enchant.
        local has, ms
        if slot == "off" then
            has, ms = ohHas, ohMs
        elseif slot == "either" then
            if ns.IsSecret(mhHas) or ns.IsSecret(ohHas) then return held(staticIcon, slot) end
            if mhHas then has, ms = true, mhMs
            elseif ohHas then has, ms = true, ohMs
            else has, ms = false, mhMs end
        else
            has, ms = mhHas, mhMs
        end
        if ns.IsSecret(has) then return held(staticIcon, slot) end

        -- FOUND — the imbue is on the weapon. Remember the timer for a later held read.
        if has then
            lastMs[slot] = ms
            return present(staticIcon, ms)
        end

        -- NOT FOUND — plain decision, same shape as the aura tracker:
        --   dead/ghost -> held  (silent; can't re-imbue a corpse)
        --   otherwise  -> missing (genuinely absent -> show the reminder)
        if ns.PlayerDead() then return held(staticIcon, slot) end
        return missing(staticIcon)
    end,
})

-- ── Choice-node Rite: one widget follows the talent swap ──────────────────
-- A single Rite widget already TRACKS both rites (the gate accepts either id and the weapon-enchant
-- read is rite-agnostic), so you never need two. This just keeps its NAME + fallback art pointed at
-- whichever Rite you currently have when you swap the talent — so the one widget also reads right.
-- Only widgets still named after a Rite (or the generic "Rite") are renamed, so a custom rename is
-- respected. The tracker's icon already resolves live via knownRiteIcon.
local function riteNameSet()
    local set = {}
    for _, id in ipairs({ 433568, 433583 }) do
        local nm = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(id)
        if nm then set[nm] = true end
    end
    set["Rite"] = true
    return set
end
local function syncRiteWidgets()
    local W = ns.profile and ns.profile.widgets
    local Tk = ns.profile and ns.profile.trackers
    if not (W and Tk) then return end
    local names, renamed = riteNameSet(), false
    for wid, c in pairs(W) do
        local tr = c.trackerId and Tk[c.trackerId]
        if tr and tr.type == "imbue" and tr.riteIds then
            local ok, id = knownRite(tr)
            if ok and id then
                tr.spellID = id   -- keep the fallback icon / click-to-cast in step with the swap
                local nm = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(id)
                if nm and c.name ~= nm and (c.name == nil or names[c.name]) then c.name = nm; renamed = true end
            end
            -- Re-bind the secure click-to-cast button to the rite you NOW have — otherwise its
            -- macro still casts the old rite until a /reload (CastSpellName resolves riteIds live).
            local w = ns.widgets and ns.widgets[wid]
            if w and w.RefreshCast then w:RefreshCast() end
        end
    end
    ns.Refresh()
    if renamed and ns.RefreshOptions then ns.RefreshOptions() end
end
local riteWatch = CreateFrame("Frame")
riteWatch:RegisterEvent("TRAIT_CONFIG_UPDATED")            -- talent (choice node) change
riteWatch:RegisterEvent("PLAYER_TALENT_UPDATE")
riteWatch:RegisterEvent("PLAYER_ENTERING_WORLD")           -- prime on login
riteWatch:SetScript("OnEvent", syncRiteWidgets)
