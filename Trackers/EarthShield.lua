-- Trackers/EarthShield.lua : "keep 2 Earth Shields out" — self + an ally, via the
-- [Elemental Orbit] talent (self-cast) alongside a normal ally cast.
--
-- Earth Shield is NOT a secret aura (ShouldSpellAuraBeSecret(974)=false), so we can
-- LIVE-SCAN the player + party/raid in and out of combat. We only ever count OUR OWN
-- shields (sourceUnit=="player") — never another shaman's Earth Shield on us or an ally.
-- The self shield is a different aura id (383648, the Elemental Orbit variant) than the
-- ally one (974), so we match either id (never secret) with a localized-name fallback.
-- With [Therazane's Resilience] it's chargeless / 60 min, so this is pure presence
-- maintenance — no charges or timers. SILENT while solo, and when the player doesn't
-- have Earth Shield at all. See mem:earthshield.

local ADDON, ns = ...

local ForEachAura = AuraUtil and AuraUtil.ForEachAura
local GetTime = GetTime
local spellIcon = ns.SpellIcon

local ES_ALLY, ES_SELF = 974, 383648   -- ally cast-on-target / Elemental Orbit self-cast
local ES_NAME                          -- localized "Earth Shield", resolved lazily

local function esName()
    if ES_NAME == nil then
        ES_NAME = (C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(ES_ALLY)) or false
    end
    return ES_NAME or nil
end


-- Raw presence read of the SELF shield (Elemental Orbit, 383648 — uniquely ours, so its
-- presence == our self shield, no source check needed). Only asks "is it there", not a
-- secret field.
local function rawSelfES()
    -- Was: pcall(GetPlayerAura, ES_SELF) then `a ~= nil` — but that compare sat OUTSIDE the
    -- pcall, so a fully-secret struct (possible in 12.1) would still have hard-errored here.
    -- ns.PlayerAura hands back a plain table or nil, so the test is always safe.
    return ns.PlayerAura(ES_SELF) ~= nil
end

-- The self shield 383648 READS RELIABLY — GetSpellAuraSecrecy(383648)=0 and it was seen readable
-- in combat via /cust secrets — so, UNLIKE Lightning Shield, a nil read here is trustworthy: the
-- shield is genuinely down. We therefore trust the live read directly. (This used to be a STICKY
-- LATCH that only cleared on death, on the mistaken assumption the self shield was combat-hidden —
-- which is why removing Earth Shield never re-warned until you reloaded.) Only a short grace after
-- a witnessed self-cast is kept, to cover the instant before the fresh aura registers.
local selfCastAt = -1e9   -- GetTime() of the last witnessed self Earth Shield cast

do
    local pendingSelf = {}     -- castGUID -> true while a self-targeted ES cast is in flight
    local me = UnitName("player")
    local w = CreateFrame("Frame")
    w:RegisterEvent("UNIT_SPELLCAST_SENT")
    w:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
    w:RegisterEvent("PLAYER_DEAD")
    w:SetScript("OnEvent", function(_, ev, ...)
        if ev == "PLAYER_DEAD" then
            selfCastAt = -1e9   -- shield drops on death; forget the post-cast grace
        elseif ev == "UNIT_SPELLCAST_SENT" then
            local unit, target, castGUID, spellID = ...
            if unit == "player" and (spellID == ES_ALLY or spellID == ES_SELF) then
                me = me or UnitName("player")
                -- self-cast if the target is us / unset (a hardcast on yourself or an @player
                -- macro); an ally's name means it went on them and doesn't arm the self latch.
                pendingSelf[castGUID] = (target == nil or target == "" or target == me)
            end
        elseif ev == "UNIT_SPELLCAST_SUCCEEDED" then
            local unit, castGUID, spellID = ...
            if unit == "player" and (spellID == ES_ALLY or spellID == ES_SELF) then
                if pendingSelf[castGUID] then
                    selfCastAt = GetTime()
                    ns.Refresh()
                end
                pendingSelf[castGUID] = nil
            end
        end
    end)
end

-- Trust the live read (383648 is readable); grace a brief window after a self-cast for the
-- fresh aura to register. A nil read outside that window means it's genuinely down -> re-warn.
local function selfShieldUp()
    if rawSelfES() then selfCastAt = -1e9; return true end   -- confirmed up: grace no longer needed
    return (GetTime() - selfCastAt) < 0.7                     -- brief bridge cast -> aura registers
end

-- Does an ALLY `unit` carry MY Earth Shield? Match either id (never secret) with a name
-- fallback, and require sourceUnit=="player" so another shaman's shield never counts.
-- Ally auras (and their source) stay readable in combat — confirmed via /cust es.
local function hasMyES(unit)
    if not (ForEachAura and UnitExists(unit)) then return false end
    local nm = esName()
    local found = false
    pcall(ForEachAura, unit, "HELPFUL", nil, function(aura)
        if not aura then return end
        local id = aura.spellId
        local match = (id == ES_ALLY or id == ES_SELF)
        if not match and nm and aura.name and not ns.IsSecret(aura.name) then match = (aura.name == nm) end
        if match and aura.sourceUnit == "player" then found = true; return true end
    end, true)
    return found
end

-- UNIT_AURA is left UNFILTERED (we need ally changes, not just the player's), so it can
-- burst in raids — coalesce scans to ~4/s. ES maintenance needs no sub-second latency.
local lastScan, cached, pending = 0, nil, false

ns.RegisterTracker("earthshield", {
    events = {
        "UNIT_AURA", "GROUP_ROSTER_UPDATE",
        "PLAYER_REGEN_ENABLED", "PLAYER_REGEN_DISABLED", "PLAYER_ENTERING_WORLD",
        "PLAYER_DEAD", "PLAYER_ALIVE", "PLAYER_UNGHOST",   -- lift the dead-gate promptly on rez
    },
    read = function(cfg)
        local now = GetTime()
        if cached and (now - lastScan) < 0.25 then
            if not pending then
                pending = true
                C_Timer.After(0.25, function()
                    pending = false
                    ns.Refresh()
                end)
            end
            return cached
        end
        lastScan = now

        local icon = cfg.icon or spellIcon(ES_ALLY)
        -- Silent (present = nil) only when you don't have Earth Shield at all. The SELF
        -- shield is maintained ALWAYS — even solo; the ALLY slot only counts in a group.
        if not (ns.SpellKnown and ns.SpellKnown(ES_ALLY)) then
            cached = { active = false, present = nil, count = 0, value = 0, max = 1, icon = icon, noCount = true }
            return cached
        end

        -- Silent while dead/ghost: you can't maintain shields as a corpse, self ES drops on
        -- death, and the fresh combat-rez frame can't read the reapplied shield yet — nagging
        -- here is pure noise. present=nil hides it until you're up and settled.
        if ns.PlayerDead() then
            cached = { active = false, present = nil, count = 0, value = 0,
                       max = IsInGroup() and 2 or 1, icon = icon, noCount = true }
            return cached
        end

        local selfUp  = selfShieldUp()
        local grouped = IsInGroup()
        local allyUp  = false
        if grouped then
            if IsInRaid() then
                for i = 1, 40 do if hasMyES("raid" .. i) then allyUp = true; break end end
            else
                for i = 1, 4 do if hasMyES("party" .. i) then allyUp = true; break end end
            end
        end

        -- Solo: just your own shield (1/1). Grouped: yours + an ally's (2/2).
        local present, n, mx
        if grouped then
            present, n, mx = (selfUp and allyUp), (selfUp and 1 or 0) + (allyUp and 1 or 0), 2
        else
            present, n, mx = selfUp, (selfUp and 1 or 0), 1
        end
        cached = {
            active  = n > 0,
            present = present or false,   -- all up => hidden; any missing => reminder shows
            count   = n, value = n, max = mx,
            icon    = icon, noCount = true,
        }
        return cached
    end,
})
