-- Trackers/Stagger.lua : Brewmaster Monk's Stagger — the delayed-damage pool.
--
-- Unlike auras/power, Stagger is READABLE in combat: UnitStagger("player") returns the current
-- staggered damage (a plain number, never secret), and UnitHealthMax gives the scale. So this is
-- a straightforward value bar — no oracle, no estimate. Its "level" (light / moderate / heavy) is
-- a fraction of max health: ≥60% heavy, ≥30% moderate, >0 light (mirrors Blizzard's own buckets
-- and MonkStaggerBarPrime). The widget colours by that fraction via a Step colour-curve.
--
-- Config: { type = "stagger", unit = "player" }

local ADDON, ns = ...

local spellIcon = ns.SpellIcon
local UnitStagger, UnitHealthMax = UnitStagger, UnitHealthMax

-- Level icons (the debuff art Blizzard shows on the player): light / moderate / heavy.
local ICON_LIGHT, ICON_MODERATE, ICON_HEAVY = 124275, 124274, 124273

ns.RegisterTracker("stagger", {
    -- UNIT_AURA catches a level (bucket) change; UNIT_MAXHEALTH rescales; the continuous drain
    -- between events is driven by the ticker below (Stagger ticks ~twice a second).
    events = { "UNIT_AURA", "UNIT_MAXHEALTH", "PLAYER_ENTERING_WORLD", "PLAYER_REGEN_ENABLED", "PLAYER_REGEN_DISABLED" },
    unitEvent = true,
    read = function(cfg)
        local unit = cfg.unit or "player"
        local s = (UnitStagger and UnitStagger(unit)) or 0
        local maxHP = (UnitHealthMax and UnitHealthMax(unit)) or 1
        if maxHP <= 0 then maxHP = 1 end
        local pct = s / maxHP
        local icon = ICON_LIGHT
        if pct >= 0.6 then icon = ICON_HEAVY elseif pct >= 0.3 then icon = ICON_MODERATE end
        return { active = s > 0, present = s > 0, count = s, value = s, max = maxHP,
                 icon = spellIcon(icon), noCount = true }
    end,
})

-- Stagger drains continuously (a DoT ticking every ~0.5s), and no event fires per tick — so while
-- it's active, re-read on a light ticker so the bar glides down instead of stepping on aura events.
-- Cheap: it only pushes when UnitStagger is actually a positive number (Brewmaster, mid-mitigation).
-- The ticker frame is only created on a Monk — every other class still registers the tracker
-- (harmless, never read) but runs no permanent OnUpdate / UnitStagger poll.
if ns.playerClass == "MONK" then
    local ticker = CreateFrame("Frame"); ticker:Hide()
    local acc = 0
    ticker:SetScript("OnUpdate", function(_, dt)
        acc = acc + dt
        if acc < 0.2 then return end
        acc = 0
        local s = UnitStagger and UnitStagger("player")
        if s and s > 0 and ns.Trackers then ns.Trackers.RefreshType("stagger") end   -- re-read just the stagger bar
    end)
    -- Only run the poll on Brewmaster (268) — a hidden frame's OnUpdate doesn't fire, so off-spec
    -- Monks pay nothing. ns.OnSpecChange fires once at build and on every spec change.
    if ns.OnSpecChange then ns.OnSpecChange(function() ticker:SetShown(ns.specID == 268) end) end
end

-- Create a Stagger bar (Brewmaster). Level-coloured via a Step colour-curve (light green →
-- moderate amber → heavy red) at the 30% / 60% thresholds; the colour-curve editor can retune it.
function ns.AddStaggerWidget()
    return ns.SpawnWidget({ type = "stagger", unit = "player" }, {
        name       = "Stagger",
        showText   = true,
        textFormat = "value",
        width      = 240, height = 26,
        colorCurve = { type = "Step", points = {
            { pct = 0.00, color = { r = 0.52, g = 0.90, b = 0.52 } },   -- light
            { pct = 0.30, color = { r = 1.00, g = 0.85, b = 0.36 } },   -- moderate
            { pct = 0.60, color = { r = 1.00, g = 0.42, b = 0.42 } },   -- heavy
        } },
    }, { specs = { [268] = true } })   -- Brewmaster spec only
end
