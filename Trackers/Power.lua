-- Trackers/Power.lua : reads a UnitPower value (Maelstrom, Mana, …).
-- Config: { type = "power", power = "MAELSTROM"|"MANA"|…, unit = "player" }

local ADDON, ns = ...

-- String keys -> Enum.PowerType, so configs/saved data stay human-readable
-- and survive even if Enum isn't loaded yet.
local POWER = {
    MANA            = (Enum and Enum.PowerType and Enum.PowerType.Mana)          or 0,
    RAGE            = (Enum and Enum.PowerType and Enum.PowerType.Rage)          or 1,
    FOCUS           = (Enum and Enum.PowerType and Enum.PowerType.Focus)         or 2,
    ENERGY          = (Enum and Enum.PowerType and Enum.PowerType.Energy)        or 3,
    COMBO_POINTS    = (Enum and Enum.PowerType and Enum.PowerType.ComboPoints)   or 4,
    RUNES           = (Enum and Enum.PowerType and Enum.PowerType.Runes)         or 5,
    RUNIC_POWER     = (Enum and Enum.PowerType and Enum.PowerType.RunicPower)    or 6,
    SOUL_SHARDS     = (Enum and Enum.PowerType and Enum.PowerType.SoulShards)    or 7,
    LUNAR_POWER     = (Enum and Enum.PowerType and Enum.PowerType.LunarPower)    or 8,  -- Balance "Astral Power"
    HOLY_POWER      = (Enum and Enum.PowerType and Enum.PowerType.HolyPower)     or 9,
    MAELSTROM       = (Enum and Enum.PowerType and Enum.PowerType.Maelstrom)     or 11,
    CHI             = (Enum and Enum.PowerType and Enum.PowerType.Chi)           or 12,
    INSANITY        = (Enum and Enum.PowerType and Enum.PowerType.Insanity)      or 13,
    ARCANE_CHARGES  = (Enum and Enum.PowerType and Enum.PowerType.ArcaneCharges) or 16,
    FURY            = (Enum and Enum.PowerType and Enum.PowerType.Fury)          or 17,
    PAIN            = (Enum and Enum.PowerType and Enum.PowerType.Pain)          or 18,
    ESSENCE         = (Enum and Enum.PowerType and Enum.PowerType.Essence)       or 19,
}
ns.PowerTypes = POWER

-- "RUNIC_POWER" -> "Runic Power": the friendly default name for a resource widget.
-- A few powers read better under their live in-game name than the enum's literal spelling
-- (LunarPower is shown as "Astral Power" in-game), so those get an explicit override.
local POWER_DISPLAY = {
    LUNAR_POWER = "Astral Power",       -- Balance druid: the enum name is legacy
    PRIMARY     = "Energy / Rage",      -- the current-form power (Druid Cat/Bear); friendly label
}
function ns.PrettyPowerName(key)
    if not key then return nil end
    if POWER_DISPLAY[key] then return POWER_DISPLAY[key] end
    return (key:gsub("_", " "):lower():gsub("(%a)([%w]*)", function(a, b) return a:upper() .. b end))
end

-- In-game resource colours, keyed by our power string. These are the curated hues a
-- new resource widget defaults to (and the wizard tints its resource button with), so
-- a Rage bar is red and a Mana bar is blue without the user touching the colour picker.
-- Values are 0-1 rgb. ESSENCE has no fixed community hue, so it falls back to
-- Blizzard's PowerBarColor at runtime (see ns.PowerColor).
local POWER_COLORS = {
    MANA           = { 0.00, 0.00, 1.00 },   -- #0000FF
    RAGE           = { 1.00, 0.00, 0.00 },   -- #FF0000
    FOCUS          = { 1.00, 0.502, 0.251 }, -- #FF8040
    ENERGY         = { 1.00, 1.00, 0.00 },   -- #FFFF00
    COMBO_POINTS   = { 1.00, 0.961, 0.412 }, -- #FFF569
    RUNES          = { 0.502, 0.502, 0.502 },-- #808080
    RUNIC_POWER    = { 0.00, 0.820, 1.00 },  -- #00D1FF
    SOUL_SHARDS    = { 0.502, 0.322, 0.549 },-- #80528C
    LUNAR_POWER    = { 0.302, 0.522, 0.902 },-- #4D85E6  (Balance "Astral Power")
    HOLY_POWER     = { 0.949, 0.902, 0.600 },-- #F2E699
    MAELSTROM      = { 0.00, 0.502, 1.00 },  -- #0080FF  (Elemental)
    CHI            = { 0.710, 1.00, 0.922 }, -- #B5FFEB
    INSANITY       = { 0.400, 0.00, 0.800 }, -- #6600CC
    ARCANE_CHARGES = { 0.102, 0.102, 0.980 },-- #1A1AFA
    FURY           = { 0.788, 0.259, 0.992 },-- #C942FD
    PAIN           = { 1.00, 0.612, 0.00 },  -- #FF9C00
}

-- Curated in-game colour for a resource, as r,g,b (0-1) + a=1, or nil if we have no
-- colour for it (the caller keeps its own default). ESSENCE has no curated hue, so we
-- borrow Blizzard's own PowerBarColor for it.
function ns.PowerColor(key)
    local c = POWER_COLORS[key]
    if c then return c[1], c[2], c[3], 1 end
    if key == "ESSENCE" and PowerBarColor and PowerBarColor.ESSENCE then
        local e = PowerBarColor.ESSENCE
        return e.r, e.g, e.b, 1
    end
    return nil
end

-- Some resources have no single hue — they read by SPEC. Death Knight runes are the case:
-- one shared rune bar that colours to the current spec (Blood red / Frost ice-blue / Unholy
-- green) instead of a flat grey. Keyed by specID; falls through to the flat RUNES colour above
-- for an unknown spec. Returns r,g,b,a or nil (nil = "no spec-specific colour, use the default").
local RUNE_SPEC_COLORS = {
    [250] = { 0.80, 0.15, 0.20 },   -- Blood  — red
    [251] = { 0.30, 0.60, 1.00 },   -- Frost  — ice blue
    [252] = { 0.40, 0.80, 0.30 },   -- Unholy — green
}
-- The spec-dynamic colour for a resource, or nil if the resource isn't spec-coloured. Only DK
-- runes qualify today. `specID` defaults to the live spec so the rune bar recolours on a swap.
function ns.PowerColorForSpec(key, specID)
    if key == "RUNES" then
        local c = RUNE_SPEC_COLORS[specID or ns.specID]
        if c then return c[1], c[2], c[3], 1 end
    end
    return nil
end

-- The in-game colour of a unit's CURRENTLY ACTIVE power (for a "PRIMARY" form-following bar):
-- UnitPowerType returns the live power token (ENERGY / RAGE / MANA / LUNAR_POWER …), which we map
-- through the curated hues above. nil if we have no colour for that token.
function ns.CurrentPowerColor(unit)
    if not UnitPowerType then return nil end
    local _, token = UnitPowerType(unit or "player")
    local c = token and POWER_COLORS[token]
    if c then return c[1], c[2], c[3], 1 end
    return nil
end

-- DISCRETE (point) resources — a small fixed ceiling, best drawn as boxes (one per
-- point): combo points, runes, holy power, chi, soul shards, arcane charges, essence.
-- The rest (Mana, Rage, Maelstrom, Runic Power, Astral Power, Insanity, Fury, Pain…) are
-- continuous pools. This gates the "segment into boxes" option and colour-by-fill.
local DISCRETE = {
    COMBO_POINTS = true, RUNES = true, SOUL_SHARDS = true,
    HOLY_POWER = true, CHI = true, ARCANE_CHARGES = true, ESSENCE = true,
}
function ns.IsDiscretePower(key) return DISCRETE[key] == true end

-- Live ceiling for a power key (UnitPowerMax is NOT secret, even in combat), so the
-- segmented bar knows how many boxes to draw — it tracks talents (e.g. 5/6/7 combo
-- points) since it's read fresh.
function ns.PowerMax(key)
    if key == "PRIMARY" then return UnitPowerMax("player") or 0 end   -- current form's power ceiling
    local pt = POWER[key]
    if not pt then return 0 end
    return UnitPowerMax("player", pt) or 0
end

-- Runes don't fire UNIT_POWER_*; they use RUNE_POWER_UPDATE. Other resources all tick
-- via the UNIT_POWER family, so only add the rune event when it's actually a rune bar.
local BASE_EVENTS = { "UNIT_POWER_FREQUENT", "UNIT_POWER_UPDATE", "UNIT_MAXPOWER", "UNIT_DISPLAYPOWER" }

-- Runes aren't a normal power: UnitPower(player, Runes) doesn't track the ready count the
-- way the other resources do (the default UI reads runes via GetRuneCooldown, not
-- UnitPower). So count the runes that are OFF cooldown directly — a readable integer
-- (never secret), which also makes the boxes crisp in combat.
local GetRuneCooldown, GetTime = GetRuneCooldown, GetTime
local function runeReadyCount()
    local ready = 0
    for i = 1, 6 do
        local start, duration, isReady = GetRuneCooldown(i)
        if isReady == true then
            ready = ready + 1
        elseif isReady == nil and start ~= nil then   -- older signature: no boolean
            if start == 0 or (duration or 0) == 0 or (start + duration) <= GetTime() then ready = ready + 1 end
        end
    end
    return ready
end

ns.RegisterTracker("power", {
    events = function(cfg)
        if cfg and cfg.power == "RUNES" then
            local e = { "RUNE_POWER_UPDATE" }
            for _, ev in ipairs(BASE_EVENTS) do e[#e + 1] = ev end
            return e
        end
        return BASE_EVENTS
    end,
    unitEvent = true,
    read = function(cfg)
        local unit = cfg.unit or "player"
        -- "PRIMARY": whatever power the current FORM/stance uses (Druid Energy in Cat, Rage in
        -- Bear, Mana in caster; also works for any class). UnitPower(unit) with no power-type
        -- returns the ACTIVE power; UNIT_DISPLAYPOWER (in BASE_EVENTS) fires on the form swap so
        -- the bar re-reads, and baseColor recolours it to the new power. Value stays secret-safe.
        if cfg.power == "PRIMARY" then
            return { value = UnitPower(unit), max = UnitPowerMax(unit), count = UnitPower(unit) }
        end
        local pt = POWER[cfg.power]
        if not pt then return { value = 0, max = 0, count = 0 } end
        -- Runes: readable ready-count from GetRuneCooldown (see above).
        if cfg.power == "RUNES" and unit == "player" then
            local n = runeReadyCount()
            local mx = UnitPowerMax("player", pt); if not mx or mx == 0 then mx = 6 end
            return { value = n, max = mx, count = n }
        end
        -- UnitPower is a SECRET even for the player in 12.0 (UnitPowerMax is
        -- not). Never compare/compute it here — pass it through untouched and
        -- let the widget hand it to secret-safe setters (SetValue/SetText).
        local value = UnitPower(unit, pt)
        local max   = UnitPowerMax(unit, pt)
        return { value = value, max = max, count = value }
    end,
})
