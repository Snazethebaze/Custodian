-- Trackers/Ally.lua : a buff you keep on SOMEONE ELSE — Source of Magic on a healer, etc.
--
-- Mirrors the ally-scan half of Trackers/EarthShield.lua: walk party/raid and count only auras
-- whose sourceUnit == "player", so another caster's same buff never counts as yours. Ally auras
-- AND their source read in combat (confirmed for Earth Shield via /cust es) — but that's per-spell,
-- so a new buff should be checked with /cust ally <id> before it's seeded (some may be secret).
--
-- Config: { type = "ally", spellID = <buff>, name = <label> }
-- Present  = MY buff is on >= 1 ally (all good, reminder hidden).
-- Missing  = in a group, spell known, alive, but the buff is out on NOBODY (reminder shows).
-- Silent (present = nil) when there's no one/nothing to fault: the spell isn't known, you're
-- SOLO (no ally to buff), or you're dead/ghost.

local ADDON, ns = ...

local ForEachAura = AuraUtil and AuraUtil.ForEachAura
local GetTime = GetTime
local spellIcon = ns.SpellIcon

-- Does this ALLY unit (never the player) carry MY copy of the buff?
local function hasMyBuff(unit, spellID)
    if not (ForEachAura and UnitExists(unit)) then return false end
    if UnitIsUnit and UnitIsUnit(unit, "player") then return false end   -- ally = someone ELSE
    local found = false
    pcall(ForEachAura, unit, "HELPFUL", nil, function(aura)
        if aura and aura.spellId == spellID and aura.sourceUnit == "player" then found = true; return true end
    end, true)
    return found
end

local function anyAllyHas(spellID)
    if not IsInGroup() then return false end
    if IsInRaid() then
        for i = 1, 40 do if hasMyBuff("raid" .. i, spellID) then return true end end
    else
        for i = 1, 4 do if hasMyBuff("party" .. i, spellID) then return true end end
    end
    return false
end

-- Public scan (also used by the /cust ally probe): true if MY buff is on any ally.
function ns.AllyBuffUp(spellID) return anyAllyHas(spellID) end

-- UNIT_AURA is UNFILTERED (we need ally changes, not just ours), so it can burst in raids —
-- coalesce scans to ~4/s per tracked spell. Ally maintenance needs no sub-second latency.
local cache = {}   -- spellID -> { snap, lastScan, pending }

local function silent(icon) return { active = false, present = nil, count = 0, value = 0, max = 1, icon = icon, noCount = true } end

ns.RegisterTracker("ally", {
    events = { "UNIT_AURA", "GROUP_ROSTER_UPDATE", "PLAYER_REGEN_ENABLED", "PLAYER_ENTERING_WORLD",
               "PLAYER_DEAD", "PLAYER_ALIVE", "PLAYER_UNGHOST" },
    read = function(cfg)
        local sid  = cfg.spellID
        local icon = cfg.icon or spellIcon(sid)
        if not sid then return silent(icon) end

        local c = cache[sid]; if not c then c = {}; cache[sid] = c end
        local now = GetTime()
        if c.snap and (now - (c.lastScan or 0)) < 0.25 then
            if not c.pending then
                c.pending = true
                C_Timer.After(0.25, function()
                    c.pending = false
                    ns.Refresh()
                end)
            end
            return c.snap
        end
        c.lastScan = now

        -- Nothing to fault: unknown spell / solo / dead -> stay silent (present = nil).
        if (ns.SpellKnown and not ns.SpellKnown(sid)) or not IsInGroup()
           or (ns.PlayerDead()) then
            c.snap = silent(icon)
            return c.snap
        end

        local up = anyAllyHas(sid)
        c.snap = { active = up, present = up or false, count = up and 1 or 0, value = up and 1 or 0,
                   max = 1, icon = icon, noCount = true }
        return c.snap
    end,
})
